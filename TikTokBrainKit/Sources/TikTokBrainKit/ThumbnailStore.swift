// ThumbnailStore.swift
//
// TikTok cover URLs are signed and expire within hours, so a URL stored on a Video is
// dead by the time the library is browsed — everything here downloads the *bytes* and
// points `thumbnailURL` at a local file under Application Support/Thumbnails.
// oEmbed is the refill: a public, auth-free endpoint that re-issues a fresh signed cover
// for any live video, so a library imported weeks ago still gets its pictures back.

import CoreGraphics
import Foundation
import ImageIO
import SwiftData
import UniformTypeIdentifiers

public enum ThumbnailStore {
    /// Long edge of the stored JPEG. A raw TikTok cover runs ~1200x1800 / 230 KB; a 640 px
    /// copy measured 40-130 KB across a sample of eight, and the largest place one is drawn
    /// is a 216 pt recipe hero.
    /// ponytail: one size for every call site — @3x on the hero, wasteful on a 44 pt row.
    private static let maxPixel = 640

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The on-disk cover for a video, or nil when nothing has been downloaded yet.
    public static func cached(videoID: String) -> URL? {
        let local = directory.appendingPathComponent("\(videoID).jpg")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// Downloads a cover image and returns the local file URL, or nil on any failure
    /// (callers fall back to the category placeholder). Existing files are reused.
    public static func download(_ remote: URL, videoID: String,
                                session: URLSession = .shared) async throws -> URL? {
        let local = directory.appendingPathComponent("\(videoID).jpg")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let (data, response) = try await session.data(from: remote)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count > 500 else {
            return nil
        }
        try (downscaled(data) ?? data).write(to: local, options: .atomic)
        return local
    }

    // MARK: - Backfill

    /// Gives every video without cover bytes a local thumbnail: its stored URL first (still
    /// valid right after an import), oEmbed second (everything older). Best effort per video —
    /// a failure just leaves the category placeholder. Cheap to call on every launch, since a
    /// cached video costs one file-existence check.
    @MainActor
    public static func backfill(container: ModelContainer, concurrency: Int = 4) async {
        let context = container.mainContext
        guard let videos = try? context.fetch(FetchDescriptor<Video>()) else { return }

        // Split first: relinking is free, fetching is not. A stored file URL that no longer
        // resolves (restore from backup moves the app container) is treated as missing.
        var pending: [(id: String, page: URL, stored: URL?)] = []
        for video in videos {
            if let local = cached(videoID: video.videoID) {
                if video.thumbnailURL != local { video.thumbnailURL = local }
            } else if !video.unavailable {
                let stored = video.thumbnailURL.flatMap { $0.isFileURL ? nil : $0 }
                pending.append((video.videoID, video.url, stored))
            }
        }
        guard !pending.isEmpty else {
            try? context.save()
            return
        }

        // oEmbed is a tiktok.com endpoint — space the calls out like the Enricher does.
        let throttle = RequestThrottle(minInterval: 0.25)
        var fetched: [String: URL] = [:]
        await withTaskGroup(of: (String, URL?).self) { group in
            var iterator = pending.makeIterator()
            func addNext() {
                guard !Task.isCancelled, let item = iterator.next() else { return }
                group.addTask {
                    (item.id, await fetch(id: item.id, page: item.page,
                                          stored: item.stored, throttle: throttle))
                }
            }
            for _ in 0..<max(1, concurrency) { addNext() }
            for await (id, local) in group {
                if let local { fetched[id] = local }
                addNext()
            }
        }

        for video in videos {
            if let local = fetched[video.videoID] { video.thumbnailURL = local }
        }
        try? context.save()
    }

    private static func fetch(id: String, page: URL, stored: URL?,
                              throttle: RequestThrottle) async -> URL? {
        if let stored, let local = await bytes(stored, id: id) { return local }
        await throttle.waitForTurn()
        let fresh = await (TikTokLink.isInstagram(page) ? instagramCover(for: page) : oEmbedCover(for: page))
        guard let fresh else { return nil }
        return await bytes(fresh, id: id)
    }

    private static func bytes(_ remote: URL, id: String) async -> URL? {
        (try? await download(remote, videoID: id)) ?? nil
    }

    /// Asks TikTok's public oEmbed endpoint for a freshly signed cover URL. Returns nil for a
    /// deleted, private or region-locked video (oEmbed answers 400) and for any parse failure.
    static func oEmbedCover(for videoURL: URL, session: URLSession = .shared) async -> URL? {
        guard let endpoint = oEmbedEndpoint(for: videoURL),
              let (data, response) = try? await session.data(from: endpoint),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return coverURL(fromOEmbed: data)
    }

    /// Instagram has no auth-free oEmbed, but a reel's public embed page carries a freshly signed
    /// cover as its `EmbeddedMediaImage`. Nil for a deleted or private reel and any parse failure.
    static func instagramCover(for videoURL: URL, session: URLSession = .shared) async -> URL? {
        guard let id = TikTokLink.videoID(in: videoURL),
              let page = TikTokLink.embedURL(for: videoURL, videoID: id) else { return nil }
        var request = URLRequest(url: page)
        request.setValue(TikTokLink.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return coverURL(fromInstagramEmbed: String(decoding: data, as: UTF8.self))
    }

    static func coverURL(fromInstagramEmbed html: String) -> URL? {
        guard let tag = html.range(of: #"<img[^>]*class="EmbeddedMediaImage"[^>]*>"#, options: .regularExpression),
              let src = html[tag].range(of: #"src="[^"]+""#, options: .regularExpression)
        else { return nil }
        return URL(string: html[src].dropFirst(5).dropLast().replacingOccurrences(of: "&amp;", with: "&"))
    }

    static func oEmbedEndpoint(for videoURL: URL) -> URL? {
        var components = URLComponents(string: "https://www.tiktok.com/oembed")
        components?.queryItems = [URLQueryItem(name: "url", value: canonicalForOEmbed(videoURL).absoluteString)]
        return components?.url
    }

    /// oEmbed only answers for the canonical `@author/video/<id>` spelling — it 400s on the
    /// `www.tiktokv.com/share/video/<id>/` form that every "Download your data" export stores,
    /// which silently left an imported library with no covers at all. The author is not in the
    /// export, but oEmbed does not check it: `@i` resolves the same as the real handle.
    static func canonicalForOEmbed(_ videoURL: URL) -> URL {
        // A URL that already carries an author is left alone — the real handle is what oEmbed
        // prefers, and rewriting it would throw away information for no gain.
        if videoURL.path.hasPrefix("/@") { return videoURL }
        guard let id = TikTokLink.videoID(in: videoURL),
              let canonical = URL(string: "https://www.tiktok.com/@i/video/\(id)")
        else { return videoURL }
        return canonical
    }

    static func coverURL(fromOEmbed data: Data) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cover = json["thumbnail_url"] as? String
        else { return nil }
        return URL(string: cover)
    }

    /// ImageIO thumbnail: decodes straight to the target size, so a full-resolution cover is
    /// never materialised as a bitmap. Returns nil when the bytes are not a decodable image,
    /// and the caller stores the original.
    static func downscaled(_ data: Data, maxPixel: Int = ThumbnailStore.maxPixel) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let output = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
