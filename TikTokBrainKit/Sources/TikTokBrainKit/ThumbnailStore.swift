// ThumbnailStore.swift
//
// TikTok cover URLs are signed and expire within hours — the pipeline downloads
// the bytes at enrich time and stores them under Application Support/Thumbnails.
// Storing pixels (not URLs) is the same rule the seed pipeline follows.

import Foundation

public enum ThumbnailStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
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
        try data.write(to: local, options: .atomic)
        return local
    }
}
