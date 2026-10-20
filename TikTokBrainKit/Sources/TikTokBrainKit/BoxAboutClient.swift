// BoxAboutClient.swift
//
// The text search matches a save against. Three pieces:
//
//   AboutItem      → what the box is told about one save
//   AboutBackfill  → which saves are still owed an about-text
//   BoxAboutClient → POST {base}/about  ({items} → one about-text per item, in order)
//
// The client is shaped exactly like `BoxEmbeddingClient`: same JWT funnel, same timeout, same
// "box unreachable" mapping. The server's side of this contract is services/webhook/about_api.py.

import Foundation

// MARK: - Request

/// One save, as the box reads it. The field names are the server's, so the encoded form is the
/// request body as it stands.
///
/// Strings a save does not have go as `""`, never `null`: the server's fields are not optional.
/// Title, topics and hashtags are deliberately absent — they are the creator's words for reach,
/// not for what the video is.
///
/// The long fields are clamped here because the server refuses the whole request, all 8 saves of
/// it, when one item's text passes 16 KB of UTF-8, and a Cyrillic letter is two bytes: one long
/// save would otherwise fail the same batch on every drain and starve every save behind it. The
/// transcript and on-screen text caps are what the server reads anyway; the four together stay
/// under 16 KB even if every letter is Cyrillic.
public struct AboutItem: Encodable, Sendable {
    static let transcriptChars = 4000
    static let ocrChars = 1000
    static let captionChars = 1500
    static let summaryChars = 1000

    public let videoID: String
    public let category: String
    public let transcript: String
    public let ocrText: String
    public let caption: String
    public let summary: String
    /// Each pick as "Title by Artist". The server uses them for the genre only.
    public let music: [String]
    /// Base64 JPEG, sent only for a save the transcript heard nothing in (`Video.hasNoSpeech`):
    /// with no words to go on, the picture is the answer. Everything else is text-only, which
    /// is the cheaper model. The caller sizes the JPEG; the server rejects one over 400 KB.
    public let image: String?

    public init(video: Video, cover: Data?) {
        videoID = video.videoID
        category = video.categoryRaw
        // Lyrics describe nothing on screen, so a music post never sends its transcript.
        transcript = video.categoryRaw == Category.music.rawValue
            ? "" : String((video.transcript ?? "").prefix(Self.transcriptChars))
        ocrText = String((video.ocrText ?? "").prefix(Self.ocrChars))
        caption = String(video.caption.prefix(Self.captionChars))
        summary = String(video.summary.prefix(Self.summaryChars))
        music = Self.musicLines(of: video)
        image = video.hasNoSpeech ? cover?.base64EncodedString() : nil
    }

    private static func musicLines(of video: Video) -> [String] {
        guard let json = video.musicJSON,
              let picks = try? JSONDecoder().decode([MusicPick].self, from: json) else { return [] }
        // An artist the video never named stays unnamed rather than reading "Title by ".
        return picks.map { $0.artist.isEmpty ? $0.title : "\($0.title) by \($0.artist)" }
    }

    /// Whether the box has anything to write from, by its own rule (`has_material` in
    /// about_api.py), which refuses the whole request (422) over an item without: a picture, or
    /// words its prompt reads. A music post's prompt never reads its transcript or summary, and
    /// no other post's reads its tracks; a caption counts without its hashtags and handles, and
    /// the analyzer's "No caption or audio was available" summary never counts.
    var hasMaterial: Bool {
        if image != nil { return true }
        let caption = caption.replacingOccurrences(
            of: #"#\w+|@[\w.]+"#, with: "", options: .regularExpression)
        let texts = category == Category.music.rawValue
            ? music + [caption, ocrText]
            : [transcript, ocrText, caption, Self.usable(summary)]
        return texts.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The summary the analyzer writes when it had nothing to go on (api_v1's prompt).
    private static let placeholderSummary = "no caption or audio was available"

    private static func usable(_ summary: String) -> String {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .hasPrefix(placeholderSummary) ? "" : summary
    }
}

// MARK: - Queue

/// Which saves still need an about-text.
public enum AboutBackfill {
    /// Analyzed, available saves whose text is older than `BoxAboutClient.revision` (or was never
    /// written), in the order given. A save Clef has only guessed a category for has no words
    /// to write from yet, and an unavailable one never will.
    ///
    /// Nor is a save with nothing to describe (`AboutItem.hasMaterial`): the box refuses it, and
    /// it would fail its batch on every drain. `hasCover` says whether the caller has a cover it
    /// would send for a save; it is asked only about a silent save, the one kind that sends one.
    ///
    /// `sendsCovers` false (the phone is on cellular) holds back every save that would go with
    /// its cover: such a save waits for Wi-Fi rather than being written text-only, which would
    /// count as done and never be written from its picture.
    public static func pending(in videos: [Video], hasCover: (Video) -> Bool = { _ in false },
                               sendsCovers: Bool = true) -> [Video] {
        videos.filter {
            guard $0.aboutRevision < BoxAboutClient.revision
                && !$0.unavailable && !$0.categoryRaw.isEmpty && !$0.isGuessed else { return false }
            let hasMaterial = AboutItem(video: $0, cover: nil).hasMaterial
            if sendsCovers { return hasMaterial || ($0.hasNoSpeech && hasCover($0)) }
            return hasMaterial && !($0.hasNoSpeech && hasCover($0))
        }
    }
}

// MARK: - Client

/// Asks the box to write one about-text per save. Batched because the caller writes a library,
/// not a sentence: the server caps a request at 8 items, so a backfill sends 8 at a time.
///
/// Moves no quota, but each item spends one unit of the box's daily about counter (its own, not
/// the deep pass's), so the server can answer 429 — callers treat any failure as "no about-text
/// yet" and leave the save pending.
public struct BoxAboutClient: Sendable {
    /// The server's cap, mirrored so the caller batches to it instead of discovering it as a 422.
    public static let maxItemsPerRequest = 8

    /// Which generation of about-text a stored one came from. Bumped when the prompt or the
    /// inputs change, which is what makes the whole library write them again.
    public static let revision = 1

    private let config: BoxConfig
    private let session: URLSession

    public init(config: BoxConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func write(_ items: [AboutItem]) async throws -> [String] {
        guard !items.isEmpty else { return [] }
        let url = config.baseURL.appendingPathComponent("about")
        var request = URLRequest(url: url, timeoutInterval: boxRequestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["items": items])

        let data = try await BoxHTTP.send(request, on: session, auth: config.auth)
        let decoded: AboutResponse
        do {
            decoded = try JSONDecoder().decode(AboutResponse.self, from: data)
        } catch {
            throw BoxError.malformedPayload("about response: \(error.localizedDescription)")
        }
        // A short answer would file a description under the wrong video, which is a worse
        // failure than none: search would be confidently wrong about it.
        guard decoded.abouts.count == items.count else {
            throw BoxError.malformedPayload(
                "about response: \(decoded.abouts.count) texts for \(items.count) items")
        }
        return decoded.abouts
    }

    private struct AboutResponse: Decodable {
        let abouts: [String]
    }
}
