// MusicPickResolver.swift
//
// Turning the releases a video named into links you can open — or leaving them as plain names
// when the catalogue has nothing that is plausibly them.
//
// Replaces `MusicLinkResolver`, and takes over the search half of `AlbumResolver`. The two used
// to differ only in which iTunes entity they asked for, and neither checked whether the answer
// resembled the question. `AlbumResolver` survives for the album detail screen's tracklist
// lookup, which is a lookup by id and cannot return the wrong record.

import Foundation

public struct MusicPickResolver: MusicLinkResolving, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Resolves every pick, leaving `link` nil on anything that does not match confidently.
    ///
    /// Sequential, like `AlbumStore.resolve`: a handful of lookups at ~200 ms against an
    /// unauthenticated public API is not worth parallelising, and hammering it invites a block.
    public func resolve(_ picks: [MusicPick]) async -> [MusicPick] {
        var resolved: [MusicPick] = []
        resolved.reserveCapacity(picks.count)
        for pick in picks {
            var pick = pick
            pick.link = try? await link(for: pick)
            resolved.append(pick)
        }
        return resolved
    }

    /// A `song.link` universal URL for the pick, or nil when nothing matched it confidently.
    ///
    /// `kind` is a preference, not a constraint. A video showing five sleeves with a title under
    /// each gives the model no reliable way to tell an album from a single — measured against
    /// the source video, it labelled all five albums "track" — so a miss on the stated kind is
    /// retried against the other. The confidence gate applies to both, so the fallback can only
    /// find a right answer, never invent one.
    public func link(for pick: MusicPick) async throws -> URL? {
        let title = pick.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        // TikTok labels stock audio "original sound" — not a release, in any catalogue.
        if title.range(of: "original sound", options: .caseInsensitive) != nil { return nil }

        if let hit = try await link(for: pick, asAlbum: pick.kind == .album) { return hit }
        return try await link(for: pick, asAlbum: pick.kind != .album)
    }

    private func link(for pick: MusicPick, asAlbum: Bool) async throws -> URL? {
        let title = pick.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(pick.artist)"
                .trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: asAlbum ? "album" : "song"),
            // More than one, unlike the code this replaces: the first hit is often a cover or a
            // compilation, and the gate below can only pick a right answer that was offered.
            URLQueryItem(name: "limit", value: "5"),
        ]
        guard let url = components?.url else { return nil }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        for hit in decoded.results {
            let returnedTitle = (asAlbum ? hit.collectionName : hit.trackName) ?? ""
            guard MatchConfidence.accepts(
                askedTitle: title, askedArtist: pick.artist,
                returnedTitle: returnedTitle, returnedArtist: hit.artistName ?? "") else { continue }
            let target = asAlbum ? hit.collectionViewUrl : hit.trackViewUrl
            guard let target, !target.isEmpty else { continue }
            return Self.songLink(for: target)
        }
        return nil   // the catalogue answered, but with nothing that is plausibly this release
    }

    /// Wraps an Apple Music URL in a percent-encoded `song.link` universal link.
    ///
    /// Unreserved characters (RFC 3986) stay; everything else — including the scheme's ":" and
    /// the path's "/" — is percent-encoded so the whole URL survives as one path component.
    static func songLink(for appleURL: String) -> URL? {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        guard let encoded = appleURL.addingPercentEncoding(withAllowedCharacters: unreserved) else {
            return nil
        }
        return URL(string: "https://song.link/\(encoded)")
    }

    private struct Response: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let trackName: String?
            let collectionName: String?
            let artistName: String?
            let trackViewUrl: String?
            let collectionViewUrl: String?
        }
    }
}
