import Foundation

/// The album a saved track belongs to, as resolved by the iTunes Search API.
public struct AlbumRef: Codable, Equatable, Sendable {
    public var collectionID: Int
    public var albumTitle: String
    public var artist: String
    public var year: Int?
    public var trackCount: Int
    public var trackNumber: Int?
    public var trackName: String
    public var albumURL: URL?
    /// The sleeve on Apple's CDN. Optional because it decodes as nil out of caches written
    /// before covers existed, and because a catalogue entry can carry no art.
    public var artworkURL: URL?
}

/// Resolves a track title/artist to its album, and an album to its full tracklist,
/// via the public iTunes Search API. Best-effort: empty titles and "original sound"
/// placeholders return `nil`, and so does a hit that does not resemble what was asked for.
public struct AlbumResolver {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func album(title: String, artist: String) async throws -> AlbumRef? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: "original sound", options: .caseInsensitive) != nil { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(trimmed) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components?.url else { return nil }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        // Gated on the way in, like `MusicPickResolver`. Without this a single save filed under
        // whatever the search happened to return first, and the album page then presented that
        // record's real tracklist as the video's content.
        guard let hit = decoded.results.first(where: {
                  MatchConfidence.accepts(
                      askedTitle: trimmed, askedArtist: artist,
                      returnedTitle: $0.trackName ?? "", returnedArtist: $0.artistName ?? "")
              }),
              let collectionID = hit.collectionId,
              let albumTitle = hit.collectionName,
              let trackCount = hit.trackCount else { return nil }
        return AlbumRef(
            collectionID: collectionID,
            albumTitle: albumTitle,
            artist: hit.artistName ?? artist,
            year: hit.releaseDate.flatMap { Int($0.prefix(4)) },
            trackCount: trackCount,
            trackNumber: hit.trackNumber,
            trackName: hit.trackName ?? trimmed,
            albumURL: hit.collectionViewUrl.flatMap(URL.init(string:)),
            artworkURL: Self.artwork(hit.artworkUrl100)
        )
    }

    /// iTunes only ever returns the 100 px sleeve, but the CDN serves any size at the same
    /// path — swapping the segment is the documented way to ask for a usable one.
    static func artwork(_ urlString: String?, size: Int = 600) -> URL? {
        guard let urlString else { return nil }
        return URL(string: urlString.replacingOccurrences(of: "100x100", with: "\(size)x\(size)"))
    }

    /// The album's track names in play order.
    public func tracklist(collectionID: Int) async throws -> [String] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(collectionID)),
            URLQueryItem(name: "entity", value: "song"),
        ]
        guard let url = components?.url else { return [] }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return decoded.results
            .filter { $0.wrapperType == "track" }
            .sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
            .compactMap(\.trackName)
    }

    private struct Response: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let wrapperType: String?
            let trackName: String?
            let artistName: String?
            let collectionId: Int?
            let collectionName: String?
            let collectionViewUrl: String?
            let artworkUrl100: String?
            let releaseDate: String?
            let trackCount: Int?
            let trackNumber: Int?
            let discNumber: Int?
        }
    }
}
