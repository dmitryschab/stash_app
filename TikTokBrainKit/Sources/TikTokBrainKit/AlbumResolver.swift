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
///
/// iTunes is asked first because it is the only one of the two that can also hand back a
/// tracklist. It is not asked alone: its Search API indexes the *purchasable* iTunes Store,
/// which has lost most streaming-only back catalogue — Death Grips' entire discography comes
/// back as singles, and Tyler, The Creator returns CHROMAKOPIA but not IGOR. Measured over one
/// real recommendation list it found 5 of 12 sleeves where Deezer found 12, which is why a
/// miss falls through to Deezer for the artwork rather than leaving a hole in the wall.
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
              let trackCount = hit.trackCount
        else { return try? await deezerAlbum(title: trimmed, artist: artist) }
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

    /// The album one pick of a recommendation list stands for. A track pick goes through
    /// `album(title:artist:)`; an album pick asks the album index directly and is matched on
    /// the collection name — "Rumours" should not have to match a song called "Rumours".
    public func album(for pick: MusicPick) async throws -> AlbumRef? {
        guard pick.kind == .album else { return try await album(title: pick.title, artist: pick.artist) }
        let trimmed = pick.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(trimmed) \(pick.artist)".trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components?.url else { return nil }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let hit = decoded.results.first(where: {
                  MatchConfidence.accepts(
                      askedTitle: trimmed, askedArtist: pick.artist,
                      returnedTitle: $0.collectionName ?? "", returnedArtist: $0.artistName ?? "")
              }),
              let collectionID = hit.collectionId,
              let albumTitle = hit.collectionName
        else { return try? await deezerAlbum(title: trimmed, artist: pick.artist) }
        return AlbumRef(
            collectionID: collectionID,
            albumTitle: albumTitle,
            artist: hit.artistName ?? pick.artist,
            year: hit.releaseDate.flatMap { Int($0.prefix(4)) },
            trackCount: hit.trackCount ?? 0,
            trackNumber: nil,
            trackName: "",
            albumURL: hit.collectionViewUrl.flatMap(URL.init(string:)),
            artworkURL: Self.artwork(hit.artworkUrl100)
        )
    }

    /// The same album out of Deezer's catalogue, for the sleeve iTunes did not have.
    ///
    /// Deliberately artwork-first: Deezer has no tracklist endpoint we use, so the ref it
    /// produces carries a **negative** `collectionID`. That is the marker for "art only" —
    /// it cannot collide with an iTunes id, it still keys the sleeve cache, and callers that
    /// would otherwise ask iTunes to look it up check the sign first (`AlbumStore.loadTracklist`).
    /// Same confidence gate as iTunes: a sleeve for the wrong record is worse than none.
    func deezerAlbum(title: String, artist: String) async throws -> AlbumRef? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Deezer's field-scoped query syntax. A bare term matches lyrics and playlists too,
        // which is exactly the loose matching the confidence gate then has to throw away.
        let query = artist.isEmpty ? "album:\"\(trimmed)\"" : "artist:\"\(artist)\" album:\"\(trimmed)\""
        var components = URLComponents(string: "https://api.deezer.com/search/album")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components?.url else { return nil }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(DeezerResponse.self, from: data)
        guard let hit = decoded.data.first(where: {
            MatchConfidence.accepts(
                askedTitle: trimmed, askedArtist: artist,
                returnedTitle: $0.title, returnedArtist: $0.artist?.name ?? "")
        }), let cover = hit.coverBig.flatMap(URL.init(string:)) else { return nil }

        return AlbumRef(
            collectionID: -hit.id,
            albumTitle: hit.title,
            artist: hit.artist?.name ?? artist,
            year: nil,
            trackCount: hit.nbTracks ?? 0,
            trackNumber: nil,
            trackName: "",
            albumURL: hit.link.flatMap(URL.init(string:)),
            artworkURL: cover
        )
    }

    private struct DeezerResponse: Decodable {
        let data: [Album]
        struct Album: Decodable {
            let id: Int
            let title: String
            let link: String?
            let coverBig: String?
            let nbTracks: Int?
            let artist: Artist?
            struct Artist: Decodable { let name: String }

            private enum CodingKeys: String, CodingKey {
                case id, title, link, artist
                case coverBig = "cover_big"
                case nbTracks = "nb_tracks"
            }
        }
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
