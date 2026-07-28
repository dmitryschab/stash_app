// TikTokLink.swift
//
// Turning a link someone shared into something the pipeline can key on.
//
// The share sheet hands over `https://vm.tiktok.com/ZMxxxx/`, which carries no video id at
// all, while both the local `Video` row and the box's `BookmarkInput` validator are keyed on
// the numeric id from the canonical `/@author/video/<id>` form. Resolving the short link means
// following its redirect and reading the final URL.

import Foundation

public enum TikTokLink {
    public enum Failure: Error, Equatable, LocalizedError {
        /// Not a TikTok at all. Never going to work — drop it.
        case notTikTok(String)
        /// TikTok answered, but not with a video: deleted, private, or a login wall. Also
        /// permanent, and the distinction from `unreachable` is the whole point of having both —
        /// a shared link is only held for another try when another try could succeed.
        case unresolved(String)
        /// The request itself failed. Worth queueing again.
        case unreachable(String)

        public var isRetryable: Bool {
            if case .unreachable = self { return true }
            return false
        }

        public var errorDescription: String? {
            switch self {
            case .notTikTok:
                "That link isn't a TikTok video — Stash can only save TikToks."
            case .unresolved:
                "Couldn't open that TikTok link. It may be private, deleted or region-locked."
            case .unreachable:
                "Couldn't reach TikTok to open that link — Stash will try again."
            }
        }
    }

    /// Accepted on the way *in*. Wider than the box's allowlist on purpose: `resolve` normalises
    /// whatever it gets to `www.tiktok.com` before anything is submitted.
    static let hostSuffix = "tiktok.com"

    /// A desktop Safari User-Agent. Same reasoning as `Enricher`: a bot-shaped UA can be served
    /// a stub or an interstitial instead of the redirect. Duplicated rather than shared because
    /// `Enricher` is the one file expected to churn whenever TikTok changes its pages.
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public static func isTikTok(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == hostSuffix || host.hasSuffix("." + hostSuffix)
    }

    /// The numeric id in a canonical `/@author/video/<id>` path, else nil. Photo posts use
    /// `/photo/<id>`, which the pipeline handles identically, so both spellings are read.
    public static func videoID(in url: URL) -> String? {
        let parts = url.path.split(separator: "/")
        guard let marker = parts.firstIndex(where: { $0 == "video" || $0 == "photo" }),
              parts.index(after: marker) < parts.endIndex else { return nil }
        let candidate = String(parts[parts.index(after: marker)])
        guard !candidate.isEmpty, candidate.allSatisfy(\.isNumber) else { return nil }
        return candidate
    }

    /// The first TikTok link in a blob of text. TikTok's own share sheet frequently hands over
    /// `public.plain-text` shaped like "caption text… https://vm.tiktok.com/ZM…" rather than a
    /// bare `public.url`, so the extension has to dig the link out of a sentence.
    public static func firstLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, isTikTok(url) { return url }
        }
        return nil
    }

    /// Follows the short link to its canonical form and returns a `Bookmark` ready to ingest.
    ///
    /// A link that already carries an id short-circuits without a request. Everything else costs
    /// one GET — `URLSession` follows the redirect chain itself and `response.url` is where it
    /// landed. A GET rather than a HEAD because TikTok's short-link host does not answer HEAD
    /// consistently; the page body is downloaded and thrown away, which is one wasted payload
    /// per shared video.
    public static func resolve(
        _ url: URL,
        session: URLSession = .shared,
        now: Date = Date()
    ) async throws -> Bookmark {
        guard isTikTok(url) else { throw Failure.notTikTok(url.absoluteString) }
        if let id = videoID(in: url) {
            return Bookmark(id: id, url: canonical(url), date: now)
        }

        var request = URLRequest(url: url)
        request.setValue(desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let final: URL?
        do {
            let (_, response) = try await session.data(for: request)
            final = (response as? HTTPURLResponse)?.url ?? response.url
        } catch {
            throw Failure.unreachable(url.absoluteString)
        }
        guard let final, isTikTok(final), let id = videoID(in: final) else {
            throw Failure.unresolved(url.absoluteString)
        }
        return Bookmark(id: id, url: canonical(final), date: now)
    }

    /// Strips the tracking query TikTok appends (`?_t=…&_r=1`) and pins scheme and host to the
    /// spellings the box allowlists, so a resolution that landed on `m.tiktok.com` still submits.
    static func canonical(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        components.scheme = "https"
        components.host = "www.tiktok.com"
        components.port = nil
        components.user = nil
        components.password = nil
        return components.url ?? url
    }
}
