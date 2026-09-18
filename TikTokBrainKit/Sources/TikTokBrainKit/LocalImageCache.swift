import Foundation
import ImageIO

/// Decoded previews for immutable local image URLs. Cache reads never touch disk.
/// NSCache is thread-safe; all file access and decoding is confined to the serial queue.
public final class LocalImageCache: @unchecked Sendable {
    public static let shared = LocalImageCache()

    private let cache = NSCache<NSURL, CGImage>()
    private let lock = NSLock()
    private var generation: UInt = 0
    private let decodeQueue = DispatchQueue(label: "dev.stash.local-image-decode", qos: .userInitiated)

    public init() {
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 0
    }

    /// Invalidates cached images and prevents older decodes from restoring them.
    public func removeAll() {
        lock.withLock {
            generation &+= 1
            cache.removeAllObjects()
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
