import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import TikTokBrainKit

final class ThumbnailStoreTests: XCTestCase {

    func testOEmbedEndpointEscapesTheVideoURL() throws {
        let page = URL(string: "https://www.tiktok.com/@someone/video/7642061063495748894")!
        let endpoint = try XCTUnwrap(ThumbnailStore.oEmbedEndpoint(for: page))
        XCTAssertEqual(endpoint.absoluteString,
                       "https://www.tiktok.com/oembed?url=https://www.tiktok.com/@someone/video/7642061063495748894")
    }

    func testCoverURLReadsThumbnailFromOEmbedPayload() throws {
        let json = #"{"version":"1.0","type":"video","thumbnail_url":"https://p16-common-sign.tiktokcdn-eu.com/x~tplv-tiktokx-origin.image?x-expires=1787522400"}"#
        let cover = try XCTUnwrap(ThumbnailStore.coverURL(fromOEmbed: Data(json.utf8)))
        XCTAssertEqual(cover.host, "p16-common-sign.tiktokcdn-eu.com")
    }

    /// A live video that oEmbed cannot describe answers with an error body, not a cover.
    func testCoverURLIsNilForAnUnavailableVideo() {
        let json = #"{"status_code":10101,"status_msg":"Something went wrong"}"#
        XCTAssertNil(ThumbnailStore.coverURL(fromOEmbed: Data(json.utf8)))
    }

    func testDownscaleShrinksACoverToTheTargetEdge() throws {
        let jpeg = try makeJPEG(width: 1233, height: 1764)
        let shrunk = try XCTUnwrap(ThumbnailStore.downscaled(jpeg, maxPixel: 640))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(shrunk as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 640)
        XCTAssertLessThan(shrunk.count, jpeg.count)
    }

    func testDownscaleReturnsNilForNonImageBytes() {
        XCTAssertNil(ThumbnailStore.downscaled(Data("<html>404</html>".utf8)))
    }

    // MARK: - Helpers

    /// A noisy gradient rather than flat colour, so JPEG cannot compress the original
    /// down to something smaller than its own thumbnail.
    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                context.setFillColor(red: CGFloat(x % 255) / 255, green: CGFloat(y % 255) / 255,
                                     blue: CGFloat((x * y) % 255) / 255, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        let image = try XCTUnwrap(context.makeImage())
        let output = try XCTUnwrap(CFDataCreateMutable(nil, 0))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
