import Foundation

/// Resolves a track title/artist to per-service links (Apple Music, Spotify, Tidal)
/// plus a `song.link` catch-all. Best-effort throughout: returns `.none` when there is
/// nothing sensible to resolve (empty title, an "original sound" placeholder, or no
/// search hit), and a service simply goes missing when its lookup fails.
///
/// Three sources, because no single one covers all three services:
///   - iTunes Search  → the Apple Music link, and the seed for Odesli.
///   - Odesli         → Tidal (and the song.link page).
///   - the box        → Spotify, which needs a client secret that can't ship in the app.
public struct MusicLinkResolver: MusicLinkResolving {
    private let session: URLSession
    private let box: BoxConfig?

    public init(session: URLSession = .shared, box: BoxConfig? = nil) {
        self.session = session
        self.box = box
    }

    public func resolve(title: String, artist: String) async throws -> TrackResolution {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .none }
        // TikTok labels stock audio as "original sound" — not resolvable to a release.
        if title.range(of: "original sound", options: [.caseInsensitive, .regularExpression]) != nil {
            return .none
        }

        guard let appleURL = try await itunesTrackURL(title: title, artist: artist) else {
            return .none
        }

        let odesli = try? await odesliLinks(seed: appleURL)
        // Odesli's own Apple link carries its affiliate tag; the iTunes one is clean.
        var byService: [MusicService: URL] = [.appleMusic: appleURL]
        byService[.tidal] = odesli?.byService[.tidal]
        // Odesli has no Spotify match for an Apple-seeded lookup, so fall back to the box.
        if let spotify = odesli?.byService[.spotify] {
            byService[.spotify] = spotify
        } else {
            byService[.spotify] = try? await boxSpotifyURL(title: title, artist: artist)
        }

        let links = MusicService.allCases.compactMap { service in
            byService[service].map { TrackLink(service: service, url: $0) }
        }
        return TrackResolution(
            universalLink: odesli?.pageURL ?? Self.songLink(for: appleURL.absoluteString),
            links: links)
    }

    // MARK: - Sources

    private func itunesTrackURL(title: String, artist: String) async throws -> URL? {
        let term = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        guard let searchURL = components?.url else { return nil }

        let (data, _) = try await session.data(from: searchURL)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard let trackViewUrl = decoded.results.first?.trackViewUrl,
              !trackViewUrl.isEmpty else {
            return nil
        }
        return URL(string: trackViewUrl)
    }

    private func odesliLinks(seed: URL) async throws -> OdesliResult {
        var components = URLComponents(string: "https://api.song.link/v1-alpha.1/links")
        components?.queryItems = [
            URLQueryItem(name: "url", value: seed.absoluteString),
            URLQueryItem(name: "userCountry", value: "US"),
        ]
        guard let url = components?.url else { return OdesliResult(pageURL: nil, byService: [:]) }

        // An error body decodes to neither field, so a failure surfaces as a decode
        // error and the caller's `try?` drops it — no status handling needed.
        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(OdesliResponse.self, from: data)

        var byService: [MusicService: URL] = [:]
        for (key, platform) in decoded.linksByPlatform {
            if let service = MusicService(rawValue: key), let url = URL(string: platform.url) {
                byService[service] = url
            }
        }
        return OdesliResult(pageURL: decoded.pageUrl.flatMap { URL(string: $0) }, byService: byService)
    }

    private func boxSpotifyURL(title: String, artist: String) async throws -> URL? {
        guard let box else { return nil }
        var components = URLComponents(
            url: box.baseURL.appendingPathComponent("music/spotify"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(box.apiKey)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(SpotifyResponse.self, from: data).url
            .flatMap { URL(string: $0) }
    }

    /// Wraps an Apple Music track URL in a percent-encoded `song.link` universal link.
    /// Used when Odesli didn't answer and so couldn't hand us its own page URL.
    static func songLink(for trackViewUrl: String) -> URL? {
        // Unreserved characters (RFC 3986) stay; everything else — including the
        // scheme's ":" and path "/" — is percent-encoded so it survives as a single
        // path component after `song.link/`.
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = trackViewUrl.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }
        return URL(string: "https://song.link/\(encoded)")
    }

    // MARK: - Payloads

    private struct OdesliResult {
        var pageURL: URL?
        var byService: [MusicService: URL]
    }

    private struct SearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let trackViewUrl: String?
        }
    }

    private struct OdesliResponse: Decodable {
        let pageUrl: String?
        let linksByPlatform: [String: Platform]
        struct Platform: Decodable { let url: String }
    }

    private struct SpotifyResponse: Decodable {
        let url: String?
    }
}
