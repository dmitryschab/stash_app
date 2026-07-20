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
}

/// Resolves a track title/artist to its album, and an album to its full tracklist,
/// via the public iTunes Search API. Best-effort with the same guard rails as
/// `MusicLinkResolver`: empty titles and "original sound" placeholders return `nil`.
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
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let url = components?.url else { return nil }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let hit = decoded.results.first,
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
            albumURL: hit.collectionViewUrl.flatMap(URL.init(string:))
        )
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
            let releaseDate: String?
            let trackCount: Int?
            let trackNumber: Int?
            let discNumber: Int?
        }
    }
}
