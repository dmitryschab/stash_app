import XCTest
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import TikTokBrainKit

final class MediaFetcherTests: XCTestCase {

    // MARK: - URLProtocol stub (serves an in-test generated video, no network)

    final class MediaStubURLProtocol: URLProtocol {
        nonisolated(unsafe) static var responseData = Data()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "video/mp4"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: MediaStubURLProtocol.responseData)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    // MARK: - Tests

    func testFetchProducesAudioAndKeyframes() async throws {
        let videoData = try await makeTestVideoData(seconds: 2.0)
        XCTAssertFalse(videoData.isEmpty, "test video generation produced no data")
        MediaStubURLProtocol.responseData = videoData

        let fetcher = MediaFetcher(session: makeStubbedSession(), keyframeCount: 6)
        let bundle = try await fetcher.fetch(streamURL: URL(string: "https://v16.example/play/test.mp4")!)

        XCTAssertNotNil(bundle.audioFileURL, "expected an exported audio file")
        if let audio = bundle.audioFileURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path), "audio file missing on disk")
            XCTAssertEqual(audio.pathExtension, "m4a")
        }
        XCTAssertEqual(bundle.keyframes.count, 6, "expected 6 evenly-spaced keyframes")
        for frame in bundle.keyframes {
            XCTAssertTrue(FileManager.default.fileExists(atPath: frame.path), "missing keyframe file")
            XCTAssertEqual(frame.pathExtension, "png")
        }

        // cleanup
        if let a = bundle.audioFileURL { try? FileManager.default.removeItem(at: a) }
        for f in bundle.keyframes { try? FileManager.default.removeItem(at: f) }
    }

    func testOCRReadsRenderedText() async throws {
        let pngURL = try renderTextPNG("PASTA")
        defer { try? FileManager.default.removeItem(at: pngURL) }
        let reader = FrameReader()
        let text = try await reader.recognizeText(in: [pngURL])
        XCTAssertTrue(text.uppercased().contains("PASTA"), "OCR output did not contain PASTA: \(text)")
    }

    // MARK: - Helpers: in-test video generation (AVAssetWriter)

    private func makeTestVideoData(seconds: Double) async throws -> Data {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let width = 320, height = 240
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false

        XCTAssertTrue(writer.canAdd(videoInput)); writer.add(videoInput)
        XCTAssertTrue(writer.canAdd(audioInput)); writer.add(audioInput)

        guard writer.startWriting() else {
            throw NSError(domain: "MediaFetcherTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "startWriting failed: \(String(describing: writer.error))"])
        }
        writer.startSession(atSourceTime: .zero)

        // Audio: one silent LPCM buffer covering the whole clip.
        if let audioBuffer = makeSilentAudio(seconds: seconds, sampleRate: 44_100) {
            while !audioInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            audioInput.append(audioBuffer)
        }
        audioInput.markAsFinished()

        // Video: solid grey frames at 15 fps.
        let fps: Int32 = 15
        let frameCount = Int(seconds * Double(fps))
        for i in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            let pb = try makePixelBuffer(width: width, height: height, gray: UInt8(40 + (i * 4) % 180))
            adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i), timescale: fps))
        }
        videoInput.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw NSError(domain: "MediaFetcherTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "finishWriting failed: \(String(describing: writer.error))"])
        }
        return try Data(contentsOf: url)
    }

    private func makeSilentAudio(seconds: Double, sampleRate: Double) -> CMSampleBuffer? {
        let channels: UInt32 = 1
        let bytesPerFrame: UInt32 = 2 * channels
        let frameCount = Int(sampleRate * seconds)
        let dataSize = frameCount * Int(bytesPerFrame)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0)

        var format: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format) == noErr, let format else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: dataSize, flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr,
            let block else { return nil }
        guard CMBlockBufferFillDataBytes(
            with: 0, blockBuffer: block, offsetIntoDestination: 0,
            dataLength: dataSize) == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid)
        var sampleSize = Int(bytesPerFrame)
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frameCount, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    private func makePixelBuffer(width: Int, height: Int, gray: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: CFDictionary = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32ARGB, attrs, &pb)
        guard status == kCVReturnSuccess, let buffer = pb else {
            throw NSError(domain: "MediaFetcherTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed (\(status))"])
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    // MARK: - Helpers: render text to PNG for the OCR test

    private func renderTextPNG(_ text: String) throws -> URL {
        let width = 600, height = 200
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "MediaFetcherTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "CGContext creation failed"])
        }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = CGPoint(x: 60, y: 70)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else {
            throw NSError(domain: "MediaFetcherTests", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "makeImage failed"])
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "MediaFetcherTests", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "CGImageDestination creation failed"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "MediaFetcherTests", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "CGImageDestination finalize failed"])
        }
        return url
    }
}
