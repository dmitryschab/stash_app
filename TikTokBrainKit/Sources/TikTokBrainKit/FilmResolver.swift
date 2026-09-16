import Foundation

/// Catalogue metadata, separate from the titles actually extracted from the source video.
public struct FilmRef: Equatable, Sendable {
    public let title: String
    public let year: Int?
    public let posterURL: URL?
    public let detailURL: URL
}

/// Wikipedia's page image is usually the theatrical poster. A missing image or an ambiguous
/// remake is a normal outcome: the caller keeps the extracted title instead of guessing.
public actor FilmResolver {
    public static let shared = FilmResolver()
    private let session: URLSession
    private struct Key: Hashable { let title: String; let year: Int? }
    private enum Cached { case found(FilmRef), missing }
    private var cache: [Key: Cached] = [:]
    private var pending: [Key: Task<FilmRef?, Error>] = [:]

    public init(session: URLSession = .shared) { self.session = session }

    public func film(for pick: FilmPick) async throws -> FilmRef? {
        try Task.checkCancellation()
        let title = pick.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let key = Key(title: Self.normalized(title), year: pick.year)
        if let cached = cache[key] {
            switch cached { case .found(let ref): return ref; case .missing: return nil }
        }
        if let task = pending[key] {
            let result = try await task.value
            try Task.checkCancellation()
            return result
        }
        let session = self.session
        let task = Task { try await Self.lookup(title: title, year: pick.year, session: session) }
        pending[key] = task
        do {
            let ref = try await task.value
            pending[key] = nil
            // Bound a long browsing session's cache; URLSession still owns HTTP caching.
            if cache.count >= 200 { cache.removeAll(keepingCapacity: true) }
            cache[key] = ref.map(Cached.found) ?? .missing
            try Task.checkCancellation()
            return ref
        } catch {
            pending[key] = nil
            throw error
        }
    }

    private static func lookup(title: String, year: Int?, session: URLSession) async throws -> FilmRef? {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        // Keep arbitrary extracted text out of MediaWiki's search operators.
        let words = title.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !words.isEmpty else { return nil }
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "intitle:\"\(words)\" film"),
            URLQueryItem(name: "gsrnamespace", value: "0"),
            URLQueryItem(name: "gsrlimit", value: "10"),
            URLQueryItem(name: "prop", value: "pageimages|pageterms|extracts|info"),
            URLQueryItem(name: "piprop", value: "thumbnail|name"),
            URLQueryItem(name: "pithumbsize", value: "300"),
            URLQueryItem(name: "pilimit", value: "10"),
            URLQueryItem(name: "pilicense", value: "any"),
            URLQueryItem(name: "wbptterms", value: "description"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "exchars", value: "400"),
            URLQueryItem(name: "exlimit", value: "10"),
            URLQueryItem(name: "inprop", value: "url"),
        ]
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Stash/1.3 (iOS; film metadata)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.error == nil else { throw URLError(.badServerResponse) }
        let expected = normalized(title)
        let candidates = (decoded.query?.pages ?? []).compactMap { page -> FilmRef? in
            guard normalized(baseTitle(page.title)) == expected else { return nil }
            let description = page.terms?.description?.first ?? ""
            // A dated film description distinguishes movies from books, games, TV series,
            // disambiguation pages, soundtracks and articles merely mentioning a film.
            guard let filmYear = releaseYear(in: description),
                  filmYear == releaseYear(in: page.extract ?? ""),
                  year == nil || year == filmYear,
                  let detail = safeURL(page.fullurl, host: "en.wikipedia.org") else { return nil }
            let portrait = page.thumbnail.map { ($0.width ?? 0) > 0 && ($0.height ?? 0) > ($0.width ?? 0) } ?? false
            return FilmRef(title: baseTitle(page.title), year: filmYear,
                           posterURL: portrait ? safeURL(page.thumbnail?.source, host: "upload.wikimedia.org") : nil,
                           detailURL: detail)
        }
        // Search order is relevance, not an identity guarantee (especially for remakes).
        let unique = Dictionary(grouping: candidates, by: \.detailURL).compactMap { $0.value.first }
        return unique.count == 1 ? unique[0] : nil
    }

    private static func safeURL(_ text: String?, host: String) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host == host,
              url.user == nil, url.password == nil, url.port == nil else { return nil }
        return url
    }

    private static func baseTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s+\((?:\d{4}\s+)?(?:[\p{L}-]+\s+)?film\)$"#,
                                   with: "", options: .regularExpression)
    }

    private static func normalized(_ title: String) -> String {
        var words = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count > 1, let first = words.first, ["a", "an", "the"].contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    private static func releaseYear(in text: String) -> Int? {
        // Descriptions start with the year; introductory sentences say "is a 2010 ... film".
        // Constrain the phrase so "2010 novel adapted into a film" cannot pass the same gate.
        let pattern = #"(?:^|\bis\s+(?:an?\s+)?)(18\d{2}|19\d{2}|20\d{2})\s+(?:(?!novel\b|book\b|series\b|soundtrack\b|album\b|game\b)[\p{L}-]+[\s,]+){0,10}films?\b"#
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
              let yearRange = text[range].range(of: #"\b(?:18|19|20)\d{2}\b"#, options: .regularExpression)
        else { return nil }
        return Int(text[yearRange])
    }

    private struct Response: Decodable {
        var query: Query?
        var error: APIError?
        struct APIError: Decodable { var code: String? }
        struct Query: Decodable { var pages: [Page]? }
        struct Page: Decodable {
            var title: String
            var fullurl: String?
            var extract: String?
            var terms: Terms?
            var thumbnail: Thumbnail?
        }
        struct Terms: Decodable { var description: [String]? }
        struct Thumbnail: Decodable { var source: String?; var width: Int?; var height: Int? }
    }
}
