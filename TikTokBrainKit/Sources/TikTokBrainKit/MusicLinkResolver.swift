import Foundation

/// Resolves a track title/artist to a universal `song.link` URL via the public
/// iTunes Search API. Best-effort: returns `nil` when there is nothing sensible
/// to resolve (empty title, an "original sound" placeholder, or no search hit).
public struct MusicLinkResolver: MusicLinkResolving {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func universalLink(title: String, artist: String) async throws -> URL? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }
        // TikTok labels stock audio as "original sound" — not resolvable to a release.
        if trimmedTitle.range(of: "original sound", options: [.caseInsensitive, .regularExpression]) != nil {
            return nil
        }

        let term = "\(trimmedTitle) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
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

        return Self.songLink(for: trackViewUrl)
    }

    /// Wraps an Apple Music track URL in a percent-encoded `song.link` universal link.
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

    private struct SearchResponse: Decodable {
        let results: [Result]
        struct Result: Decodable {
            let trackViewUrl: String?
        }
    }
}
