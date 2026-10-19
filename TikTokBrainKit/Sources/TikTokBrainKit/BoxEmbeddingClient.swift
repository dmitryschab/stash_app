// BoxEmbeddingClient.swift
//
// The meaning half of search. Two pieces, both small enough to live together:
//
//   BoxEmbeddingClient → POST {base}/embeddings  ({texts} → one vector per text)
//   EmbeddingVector    → the packed Float32 blob a `Video` stores, and cosine over it
//
// The client is shaped exactly like the other `BoxClients`: same JWT funnel, same timeout, same
// "box unreachable" mapping. Ranking with these vectors is `SearchIndex` (SearchRanking.swift).

import Foundation

// MARK: - Client

/// Asks the box for one vector per text. Batched because the caller embeds a library, not a
/// sentence: the server caps a request at 32 texts, so a backfill sends 32 at a time.
///
/// Costs no quota — the box charges nothing for this route — but it is still a network call, and
/// every caller here treats a failure as "no embedding" rather than as an error worth showing.
public struct BoxEmbeddingClient: Sendable {
    /// The server's cap, mirrored so the caller batches to it instead of discovering it as a 422.
    public static let maxTextsPerRequest = 32

    /// Which generation of embeddings a stored vector came from. Bumped when the model or the
    /// text recipe changes, which is what makes the whole library re-embed. 2: the text became
    /// the about-text (`Video.about`) instead of title, topics, caption and transcript.
    public static let revision = 2

    private let config: BoxConfig
    private let session: URLSession

    public init(config: BoxConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let url = config.baseURL.appendingPathComponent("embeddings")
        var request = URLRequest(url: url, timeoutInterval: boxRequestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["texts": texts])

        let data = try await BoxHTTP.send(request, on: session, auth: config.auth)
        let decoded: EmbeddingsResponse
        do {
            decoded = try JSONDecoder().decode(EmbeddingsResponse.self, from: data)
        } catch {
            throw BoxError.malformedPayload("embeddings response: \(error.localizedDescription)")
        }
        // A short answer would silently pair vectors with the wrong videos, which is a worse
        // failure than no search at all: every result would be confidently wrong.
        guard decoded.vectors.count == texts.count else {
            throw BoxError.malformedPayload(
                "embeddings response: \(decoded.vectors.count) vectors for \(texts.count) texts")
        }
        return decoded.vectors
    }

    private struct EmbeddingsResponse: Decodable {
        let vectors: [[Float]]
        let model: String
        let dims: Int
    }
}

// MARK: - Storage and similarity

/// How a vector crosses into SwiftData and back: packed little-endian Float32, four bytes each.
///
/// Packed rather than `[Float]` on the model because SwiftData would store the array as a
/// transformable blob anyway, and because the endianness then belongs to us instead of to
/// whatever archiver ships next.
public enum EmbeddingVector {
    public static func pack(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func unpack(_ data: Data) -> [Float] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { start in
            var bits: UInt32 = 0
            for offset in 0..<4 { bits |= UInt32(bytes[start + offset]) << (8 * offset) }
            return Float(bitPattern: bits)
        }
    }

    /// Cosine similarity, clamped to 0...1.
    ///
    /// Clamped because a negative cosine means "unrelated", not "worse than nothing": every
    /// unrelated save scores the same 0 rather than being ordered by how unrelated it is.
    /// Mismatched or empty vectors score 0 rather than trapping — a stored vector from an older
    /// model is exactly that case, and it must degrade to lexical, not crash the library list.
    ///
    /// ponytail: a plain loop, not Accelerate. 1200 x 256 floats is a fraction of a millisecond,
    /// and this way the same code is what the tests measure.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for (x, y) in zip(a, b) {
            dot += Double(x) * Double(y)
            normA += Double(x) * Double(x)
            normB += Double(y) * Double(y)
        }
        guard normA > 0, normB > 0 else { return 0 }
        return max(0, min(1, dot / (normA.squareRoot() * normB.squareRoot())))
    }
}
