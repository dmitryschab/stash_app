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
public struct AboutItem: Encodable, Sendable {
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
        transcript = video.transcript ?? ""
        ocrText = video.ocrText ?? ""
        caption = video.caption
        summary = video.summary
        music = Self.musicLines(of: video)
        image = video.hasNoSpeech ? cover?.base64EncodedString() : nil
    }

    private static func musicLines(of video: Video) -> [String] {
        guard let json = video.musicJSON,
              let picks = try? JSONDecoder().decode([MusicPick].self, from: json) else { return [] }
        // An artist the video never named stays unnamed rather than reading "Title by ".
        return picks.map { $0.artist.isEmpty ? $0.title : "\($0.title) by \($0.artist)" }
    }
}

// MARK: - Queue

/// Which saves still need an about-text.
public enum AboutBackfill {
    /// Analyzed, available saves whose text is older than `BoxAboutClient.revision` (or was never
    /// written), in the order given. A save Clef has only guessed a category for has no words
    /// to write from yet, and an unavailable one never will.
    public static func pending(in videos: [Video]) -> [Video] {
        videos.filter {
            $0.aboutRevision < BoxAboutClient.revision
                && !$0.unavailable && !$0.categoryRaw.isEmpty && !$0.isGuessed
        }
    }
}

// MARK: - Client

/// Asks the box to write one about-text per save. Batched because the caller writes a library,
/// not a sentence: the server caps a request at 8 items, so a backfill sends 8 at a time.
///
/// Moves no quota, but each item spends one of the day's deep-pass units, so the server can
/// answer 429 — callers treat any failure as "no about-text yet" and leave the save pending.
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
