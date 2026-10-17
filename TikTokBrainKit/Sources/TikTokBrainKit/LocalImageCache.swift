import Foundation
import ImageIO

/// Decoded previews for immutable local image URLs. Cache reads never touch disk.
/// NSCache is thread-safe, and ImageIO decodes are independent, so the queue is concurrent:
/// a wall of forty sleeves used to arrive one per decode, now a few per frame.
public final class LocalImageCache: @unchecked Sendable {
    public static let shared = LocalImageCache()

    private let cache = NSCache<NSURL, CGImage>()
    private let lock = NSLock()
    private var generation: UInt = 0
    // ponytail: GCD caps the width itself; a semaphore if a cold wall ever starves the UI thread.
    private let decodeQueue = DispatchQueue(label: "dev.stash.local-image-decode",
                                            qos: .userInitiated, attributes: .concurrent)

    public init() {
        // A 600 px decode costs ~1 MB; the launch prewarm holds up to ~90 of them for seven
        // slots, and the limit has to leave room for the tab being scrolled on top of that.
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 0
    }

    /// Invalidates cached images and prevents older decodes from restoring them.
    public func removeAll() {
        lock.withLock {
            generation &+= 1
            cache.removeAllObjects()
        }
    }

    /// Decodes ahead of display so the first frame of a tab is a cache hit, not a placeholder.
    /// Runs off the caller's thread and returns at once; a URL already cached costs a lookup.
    public func prewarm(_ urls: [URL]) {
        for url in urls where url.isFileURL && cachedImage(for: url) == nil {
            Task(priority: .utility) { _ = await self.image(for: url) }
        }
    }

    public func cachedImage(for url: URL) -> CGImage? {
        cache.object(forKey: url as NSURL)
    }

    public func image(for url: URL) async -> CGImage? {
        guard url.isFileURL, !Task.isCancelled else { return nil }
        if let image = cachedImage(for: url) { return image }
        let requestGeneration = lock.withLock { generation }
        return await withCheckedContinuation { continuation in
            decodeQueue.async { [self] in
                guard lock.withLock({ generation == requestGeneration }) else {
                    continuation.resume(returning: nil)
                    return
                }
                // Several visible cards may request the same file while the first decode runs.
                if let image = cachedImage(for: url) {
                    continuation.resume(returning: image)
                    return
                }
                let image: CGImage? = autoreleasepool {
                    guard let source = CGImageSourceCreateWithURL(url as CFURL,
                        [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 600,
                        kCGImageSourceShouldCacheImmediately: true
                    ] as CFDictionary)
                }
                let currentImage: CGImage? = lock.withLock {
                    guard generation == requestGeneration else { return nil }
                    if let image {
                        cache.setObject(image, forKey: url as NSURL,
                                        cost: image.bytesPerRow * image.height)
                    }
                    return image
                }
                continuation.resume(returning: currentImage)
            }
        }
    }
}
