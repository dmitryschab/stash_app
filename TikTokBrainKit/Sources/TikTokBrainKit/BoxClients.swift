// BoxClients.swift
//
// Thin HTTP clients for the self-hosted "model box" over Tailscale, following AtlasFlow's
// DiffusionGemma pattern: OpenAI-compatible endpoints, base URL from runtime config (never
// committed), placeholder API key, a distinct "box unreachable" error, ~30 s timeout.
//
//   TranscriberClient → POST {base}/audio/transcriptions  (Whisper, multipart upload)
//   AnalyzerClient    → POST {base}/chat/completions        (structured JSON output → Analysis)

import Foundation

// MARK: - Shared box networking

/// Cold-model loads on the box can be slow; allow a generous per-request timeout.
private let boxRequestTimeout: TimeInterval = 30

private enum BoxHTTP {
    /// URLSession transport errors that indicate the box/tailnet is not reachable.
    static func mapTransportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cannotConnectToHost, .timedOut, .dnsLookupFailed,
             .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
            return BoxError.unreachable(
                "(is Tailscale up and the box online?) \(urlError.localizedDescription)"
            )
        default:
            return error
        }
    }

    /// Throws `BoxError.badResponse` for any non-2xx status.
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw BoxError.badResponse(http.statusCode)
        }
    }

    /// Runs the request, mapping transport failures and validating the status code.
    static func send(_ request: URLRequest, on session: URLSession) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapTransportError(error)
        }
        try validate(response)
        return data
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

// MARK: - TranscriberClient

/// Asks the box for a transcript of a TikTok video by URL. The box downloads the
/// audio itself (yt-dlp — TikTok blocks all in-app media fetches), runs cloud
/// Whisper with language auto-detect, and applies the repetition filter; a nil
/// transcript is the normal music/no-speech outcome, and `unavailable` marks
/// deleted/private videos. Downloads + throttling make this the slow call, hence
/// its own generous timeout.
public struct TranscriberClient: Transcribing {
    private let config: BoxConfig
    private let session: URLSession
    private static let transcriptTimeout: TimeInterval = 180

    public init(config: BoxConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func transcript(for videoURL: URL) async throws -> String? {
        let url = config.baseURL.appendingPathComponent("videos/transcript")
        var request = URLRequest(url: url, timeoutInterval: Self.transcriptTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": videoURL.absoluteString])

        let data = try await BoxHTTP.send(request, on: session)
        do {
            return try JSONDecoder().decode(TranscriptResponse.self, from: data).transcript
        } catch {
            throw BoxError.malformedPayload("transcript response: \(error.localizedDescription)")
        }
    }

    private struct TranscriptResponse: Decodable {
        let transcript: String?
        let unavailable: Bool?
    }
}

// MARK: - AnalyzerClient

/// Sends caption/transcript/OCR context to the box's chat endpoint and decodes the model's
/// structured JSON into `Analysis`. Requests a JSON object response and strips any Markdown
/// code fences the model may still wrap around its output.
public struct AnalyzerClient: Analyzing {
    private let config: BoxConfig
    private let session: URLSession

    public init(config: BoxConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func analyze(meta: VideoMeta, transcript: String?, ocrText: String?) async throws -> Analysis {
        let request = try makeRequest(meta: meta, transcript: transcript, ocrText: ocrText)
        let data = try await BoxHTTP.send(request, on: session)

        let content: String
        do {
            let chat = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let message = chat.choices.first?.message.content else {
                throw BoxError.malformedPayload("chat response: no choices")
            }
            content = message
        } catch let error as BoxError {
            throw error
        } catch {
            throw BoxError.malformedPayload("chat response: \(error.localizedDescription)")
        }

        let json = Self.stripCodeFences(content)
        do {
            return try JSONDecoder().decode(Analysis.self, from: Data(json.utf8))
        } catch {
            throw BoxError.malformedPayload("analysis json: \(error.localizedDescription)")
        }
    }

    private func makeRequest(meta: VideoMeta, transcript: String?, ocrText: String?) throws -> URLRequest {
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url, timeoutInterval: boxRequestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")

        let payload: [String: Any] = [
            "model": config.chatModel,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": Self.userPrompt(meta: meta, transcript: transcript, ocrText: ocrText)],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Instructs the model to emit exactly the `Analysis` JSON shape.
    static let systemPrompt = """
    You classify a short video into a single strict JSON object. Respond with ONLY the JSON \
    object, no prose and no Markdown code fences. Use this exact shape:
    {
      "category": "recipe" | "music" | "coding" | "other",
      "title": string,
      "summary": string,
      "topics": [string],            // short lowercase topic keywords
      "recipe": { "name": string, "ingredients": [string], "steps": [string] } | null,
      "track": { "title": string, "artist": string, "universalLink": null } | null,
      "code": { "summary": string, "links": [string], "techTags": [string] } | null
    }
    Include only the payload object that matches the chosen category and set the other two to \
    null. Set "universalLink" to null; the app resolves music links separately. If information \
    is missing, use empty strings or empty arrays rather than inventing details.
    Rules (validated on an 855-video run — see pipeline-lab/PROMPT.md):
    - Captions and transcripts may be in any language; ALWAYS answer in English. \
    Title max 60 characters.
    - Classify from caption hashtags even when the transcript is empty: #linux #arch \
    #selfhosted #homelab #docker #python #react #vim -> "coding"; cooking/baking/food -> \
    "recipe"; a song/lyrics/album -> "music".
    - Music: if the video is an album/artist RECOMMENDATION LIST (not one song), set \
    track.title to the list's theme and track.artist to the main artist(s), or "" if several. \
    For one song, identify title+artist from well-known lyrics — but NEVER invent an artist \
    you are not confident about; use "" instead of guessing.
    - NEVER output placeholder text like "No Content Provided"/"Untitled Video". If caption \
    and transcript are both empty: title "Saved video", summary "No caption or audio was \
    available for this save."
    """

    static func userPrompt(meta: VideoMeta, transcript: String?, ocrText: String?) -> String {
        var parts: [String] = []
        if !meta.caption.isEmpty { parts.append("Caption: \(meta.caption)") }
        if !meta.hashtags.isEmpty { parts.append("Hashtags: \(meta.hashtags.joined(separator: ", "))") }
        if !meta.author.isEmpty { parts.append("Author: \(meta.author)") }
        if let title = meta.soundTitle, !title.isEmpty {
            let artist = meta.soundArtist.map { " by \($0)" } ?? ""
            parts.append("Sound: \(title)\(artist)")
        }
        if let transcript, !transcript.isEmpty { parts.append("Transcript: \(transcript)") }
        if let ocrText, !ocrText.isEmpty { parts.append("On-screen text: \(ocrText)") }
        if parts.isEmpty { parts.append("(no metadata available)") }
        return parts.joined(separator: "\n")
    }

    /// Removes a leading ```/```json fence and trailing ``` if the model wrapped its JSON.
    static func stripCodeFences(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        if let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        } else {
            text = String(text.dropFirst(3))
        }
        if let closing = text.range(of: "```", options: .backwards) {
            text = String(text[..<closing.lowerBound])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
        }
        let choices: [Choice]
    }
}
