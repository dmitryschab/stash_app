// A pick's picture comes from two places: the shop page's product photo, fetched with the
// offers, and the video frame whose on-screen text names the pick. Both live beside the covers;
// when both exist the catalog photo is the one the rows draw.

import Foundation
import Testing
@testable import TikTokBrainKit

@Suite("Pick pictures")
struct PickPictureTests {

    /// A 1x1 PNG — enough for ImageIO to decode and re-encode.
    static let pixel = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aProductPictureOutranksTheVideoFrame() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("frame.png")
        try Self.pixel.write(to: png)

        #expect(PickFrames.storeFrame(png: png, videoID: "v1", pickIndex: 0, directory: dir) != nil)
        #expect(PickFrames.picture(videoID: "v1", pickIndex: 0, directory: dir)
                == PickFrames.frameURL(videoID: "v1", pickIndex: 0, directory: dir))

        #expect(PickFrames.storeProductImage(Self.pixel, videoID: "v1", pickIndex: 0, directory: dir) != nil)
        #expect(PickFrames.picture(videoID: "v1", pickIndex: 0, directory: dir)
                == PickFrames.productImageURL(videoID: "v1", pickIndex: 0, directory: dir))
        #expect(PickFrames.picture(videoID: "v1", pickIndex: 1, directory: dir) == nil)
    }

    @Test func bytesThatAreNotAnImageStoreNothing() throws {
        // A shop that answers the image URL with a captcha page must not become the picture.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = Data("<html>Are you a robot?</html>".utf8)
        #expect(PickFrames.storeProductImage(html, videoID: "v1", pickIndex: 0, directory: dir) == nil)
        #expect(PickFrames.picture(videoID: "v1", pickIndex: 0, directory: dir) == nil)
    }
}
