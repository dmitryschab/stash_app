import Foundation
import ImageIO
import Testing
@testable import TikTokBrainKit

@Suite("Local image cache")
struct LocalImageCacheTests {
    private func imageFile(width: Int = 8, height: Int = 4) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func warmImagesAreAvailableSynchronouslyWithoutReadingTheFileAgain() async throws {
        let url = try imageFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = LocalImageCache()
        #expect(cache.cachedImage(for: url) == nil)
        let loaded = try #require(await cache.image(for: url))
        try FileManager.default.removeItem(at: url)
        #expect(cache.cachedImage(for: url) === loaded)
        #expect(await cache.image(for: url) === loaded)
        #expect(cache.cachedImage(for: url.appendingPathExtension("other")) == nil)
    }

    @Test func largeImagesAreDownsampledBeforeCaching() async throws {
        let url = try imageFile(width: 2400, height: 1200)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try #require(await LocalImageCache().image(for: url))
        #expect(image.width == 600)
        #expect(image.height == 300)
    }

    @Test func missingFilesCanLoadAfterTheyArrive() async throws {
        let existing = try imageFile()
        let destination = existing.appendingPathExtension("later")
        defer {
            try? FileManager.default.removeItem(at: existing)
            try? FileManager.default.removeItem(at: destination)
        }
        let cache = LocalImageCache()
        #expect(await cache.image(for: destination) == nil)
        try FileManager.default.moveItem(at: existing, to: destination)
        #expect(await cache.image(for: destination) != nil)
    }

    @Test func clearingTheCacheReloadsAReplacedFile() async throws {
        let url = try imageFile()
        let replacement = try imageFile(width: 16, height: 8)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: replacement)
        }
        let cache = LocalImageCache()
        #expect(await cache.image(for: url)?.width == 8)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: replacement, to: url)
        cache.removeAll()
        #expect(cache.cachedImage(for: url) == nil)
        #expect(await cache.image(for: url)?.width == 16)
    }

    @Test func remoteURLsAreNotLoadedByTheLocalCache() async throws {
        let cache = LocalImageCache()
        let url = try #require(URL(string: "https://example.com/image.png"))
        #expect(await cache.image(for: url) == nil)
    }
}
