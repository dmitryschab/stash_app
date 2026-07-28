// MediaFetcher.swift
//
// Task 6: downloads a video stream, extracts an audio file for transcription and a
// handful of evenly-spaced keyframes for on-device OCR.
//
// - `MediaFetcher` (conforms to `MediaFetching`): stream URL -> `MediaBundle`.
// - `FrameReader`: keyframe PNGs -> recognized on-screen text via Vision OCR.
//
// All output lives in temporary files. Callers own the returned URLs and are
// responsible for deleting them once analysis is done (see spec: "Temp files
// deleted after analysis; only thumbnails persist").

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

public struct MediaFetcher: MediaFetching {
    private let session: URLSession
    private let keyframeCount: Int

    public init(session: URLSession = .shared, keyframeCount: Int = 6) {
        self.session = session
        self.keyframeCount = keyframeCount
    }

    /// Downloads `streamURL` to a temporary `.mp4`, exports an `.m4a` audio track,
    /// and samples `keyframeCount` evenly-spaced frames to temporary PNGs.
    ///
    /// Best-effort by design: if the source has no audio track the bundle's
    /// `audioFileURL` is `nil`; if it has no usable video track `keyframes` is empty.
    /// The intermediate `.mp4` is deleted before returning.
    public func fetch(streamURL: URL) async throws -> MediaBundle {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiktokbrain-media", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let videoURL = workDir.appendingPathComponent(UUID().uuidString + ".mp4")
        let (data, _) = try await session.data(from: streamURL)
        try data.write(to: videoURL)
        defer { try? FileManager.default.removeItem(at: videoURL) }

        let asset = AVURLAsset(url: videoURL)
        let audioFileURL = try await exportAudio(from: asset, into: workDir)
        let keyframes = try await extractKeyframes(from: asset, into: workDir)

        return MediaBundle(audioFileURL: audioFileURL, keyframes: keyframes)
    }

    /// Samples keyframes from an already-downloaded local video file, skipping the audio
    /// export `fetch` performs — the visual pass only needs frames, and exporting audio
    /// across a whole library is pure waste. The caller owns `fileURL` and the returned PNGs.
    public func keyframes(fromLocalFile fileURL: URL) async throws -> [URL] {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tiktokbrain-media", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        return try await extractKeyframes(from: AVURLAsset(url: fileURL), into: workDir)
    }

    // MARK: - Audio

    /// Exports the asset's audio track to a temporary `.m4a` (AAC) file for the
    /// Whisper client. Returns `nil` when the asset carries no audio track.
    ///
    /// Uses `AVAssetExportSession` with the AppleM4A preset. (The preset keeps the
    /// source sample rate/channel layout; downstream Whisper handles resampling.)
    private func exportAudio(from asset: AVURLAsset, into dir: URL) async throws -> URL? {
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { return nil }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }

        let outURL = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        export.outputURL = outURL
        export.outputFileType = .m4a

        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }

        guard export.status == .completed else { return nil }
        return outURL
    }

    // MARK: - Keyframes

    /// Samples `keyframeCount` evenly-spaced frames (at segment midpoints) and
    /// writes each to a temporary PNG. Returns an empty array for zero-length or
    /// audio-only assets.
    private func extractKeyframes(from asset: AVURLAsset, into dir: URL) async throws -> [URL] {
        guard keyframeCount > 0 else { return [] }

        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return [] }

        let hasVideo = try await !asset.loadTracks(withMediaType: .video).isEmpty
        guard hasVideo else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var urls: [URL] = []
        for index in 0..<keyframeCount {
            let fraction = (Double(index) + 0.5) / Double(keyframeCount)
            let time = CMTime(seconds: seconds * fraction, preferredTimescale: 600)
            let cgImage = try await generator.image(at: time).image
            let url = dir.appendingPathComponent(UUID().uuidString + ".png")
            try Self.writePNG(cgImage, to: url)
            urls.append(url)
        }
        return urls
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

/// On-device OCR over keyframe PNGs using Vision's accurate English recognizer.
///
/// Emits one line per frame — `[n] top line | next line | …` — rather than a flat pool of unique
/// strings. Which frame a word came from is the only signal that says a title and an artist
/// belong together, and flattening threw it away: a video listing five albums produced one
/// alphabet soup, and the analyzer paired "Polaris" with "M" and "KMC" with nothing. Grouped by
/// frame and ordered top-to-bottom, the same video reads as five correct title/artist pairs.
///
/// Frames whose text is identical to one already emitted are dropped, which is most of them —
/// on-screen text changes far more slowly than twelve evenly-spaced samples.
public struct FrameReader: Sendable {
    public init() {}

    /// Marks the grouped format. Text stored before this change has no frame markers, which is
    /// how `PipelineRunner.backfillVisualText` knows it is worth re-reading.
    public static let frameMarker = "["

    public func recognizeText(in imageURLs: [URL]) async throws -> String {
        var blocks: [String] = []
        var seen = Set<String>()

        for (index, url) in imageURLs.enumerated() {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            // Reading order: Vision's boundingBox origin is bottom-left, so the highest maxY is
            // the topmost line. A title sits above its artist on essentially every such card.
            let observations = (request.results ?? [])
                .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            let lines = observations.compactMap { observation -> String? in
                let text = observation.topCandidates(1).first?.string
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (text?.isEmpty ?? true) ? nil : text
            }
            guard !lines.isEmpty else { continue }

            let block = lines.joined(separator: " | ")
            guard seen.insert(block).inserted else { continue }
            blocks.append("[\(index + 1)] \(block)")
        }

        return blocks.joined(separator: "\n")
    }
}
