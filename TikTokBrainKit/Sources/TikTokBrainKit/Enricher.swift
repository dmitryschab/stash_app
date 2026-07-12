import Foundation

/// Fetches a public TikTok video page and parses the embedded rehydration JSON
/// into a `VideoMeta`. The single most fragile parser in the pipeline, isolated
/// here so a TikTok page change is a one-file fix.
public struct Enricher: Enriching {

    private let session: URLSession
    private let throttle: RequestThrottle

    public init(session: URLSession = .shared, minRequestInterval: TimeInterval = 1.0) {
        self.session = session
        self.throttle = RequestThrottle(minInterval: minRequestInterval)
    }

    /// A desktop Safari User-Agent — TikTok serves the rehydration JSON to
    /// desktop browsers; a mobile/bot UA can be redirected or served a stub.
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public func enrich(_ url: URL) async throws -> VideoMeta {
        await throttle.waitForTurn()
        var request = URLRequest(url: url)
        request.setValue(Self.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        return try parse(html: html)
    }

    public func parse(html: String) throws -> VideoMeta {
        guard let root = Self.extractUniversalData(from: html) else {
            throw BoxError.malformedPayload(
                "__UNIVERSAL_DATA_FOR_REHYDRATION__ script tag not found or not valid JSON")
        }

        // __DEFAULT_SCOPE__ -> webapp.video-detail -> itemInfo -> itemStruct
        let scope = root["__DEFAULT_SCOPE__"] as? [String: Any]
        let detail = scope?["webapp.video-detail"] as? [String: Any]
        let itemInfo = detail?["itemInfo"] as? [String: Any]
        let item = itemInfo?["itemStruct"] as? [String: Any] ?? [:]

        let desc = item["desc"] as? String ?? ""
        let author = (item["author"] as? [String: Any])?["uniqueId"] as? String ?? ""

        let music = item["music"] as? [String: Any]
        let soundTitle = music?["title"] as? String
        let soundArtist = music?["authorName"] as? String

        let video = item["video"] as? [String: Any]
        let thumbnailURL = (video?["cover"] as? String).flatMap(URL.init(string:))
        let streamURL = (video?["playAddr"] as? String).flatMap(URL.init(string:))

        return VideoMeta(
            caption: desc,
            hashtags: Self.extractHashtags(from: desc),
            author: author,
            thumbnailURL: thumbnailURL,
            soundTitle: soundTitle,
            soundArtist: soundArtist,
            streamURL: streamURL
        )
    }

    // MARK: - Parsing helpers

    /// String-scans for the rehydration `<script>` tag and JSON-parses its body.
    /// Returns nil when the tag is absent or its contents are not a JSON object.
    static func extractUniversalData(from html: String) -> [String: Any]? {
        guard let marker = html.range(of: "__UNIVERSAL_DATA_FOR_REHYDRATION__") else { return nil }
        // End of the opening `<script ...>` tag.
        guard let tagClose = html.range(of: ">", range: marker.upperBound..<html.endIndex) else { return nil }
        // Matching `</script>`.
        guard let scriptEnd = html.range(of: "</script>", range: tagClose.upperBound..<html.endIndex) else { return nil }

        let jsonSlice = html[tagClose.upperBound..<scriptEnd.lowerBound]
        guard let data = jsonSlice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    /// Whitespace-separated words starting with `#`, `#` stripped and lowercased.
    static func extractHashtags(from desc: String) -> [String] {
        desc.split(whereSeparator: { $0.isWhitespace })
            .compactMap { word in
                guard word.hasPrefix("#") else { return nil }
                let tag = word.dropFirst().lowercased()
                return tag.isEmpty ? nil : tag
            }
    }
}

/// Serialises page fetches so requests are spaced at least `minInterval` apart,
/// throttling the fragile Enricher against TikTok blocking. Actor-guarded so the
/// slot reservation is atomic even under concurrent callers.
actor RequestThrottle {
    private let minInterval: TimeInterval
    private var nextAllowed: Date = .distantPast

    init(minInterval: TimeInterval) {
        self.minInterval = minInterval
    }

    func waitForTurn() async {
        let now = Date()
        // Reserve this slot before any suspension so concurrent callers queue.
        let scheduled = max(now, nextAllowed)
        nextAllowed = scheduled.addingTimeInterval(minInterval)
        let delay = scheduled.timeIntervalSince(now)
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}
