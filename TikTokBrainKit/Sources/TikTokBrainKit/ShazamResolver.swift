// ShazamResolver.swift
//
// Naming the song that is actually playing.
//
// ~71 music saves carry a title and an empty artist. That is not a bug in the prompt — the prompt
// forbids the model from guessing one, because an invented artist is how the wrong release gets
// linked, and `pipeline-lab/PROMPT.md` names the only real fix: a music-ID service on the audio.
// ShazamKit is that service. It runs on device, matches from a file, needs no microphone
// permission, and the audio is already on disk: the deep pass downloads the mp4 for OCR and
// deletes it in the same statement group. This is a second read of a file we already paid for.
//
// Best-effort from end to end. No audio track, no network, no match, any error at all — nothing
// is written and no stage fails. The video keeps the artist it had, which is none.

import AVFoundation
import Foundation
import ShazamKit

/// One recording ShazamKit recognised in a video's audio.
public struct AudioMatch: Equatable, Sendable {
    public let title: String
    public let artist: String
    /// The catalogue's own link for the recording, when it carries one. Only ever a starting
    /// point: `MusicPickResolver` still gets to look the pick up properly.
    public let appleMusicURL: URL?

    public init(title: String, artist: String, appleMusicURL: URL? = nil) {
        self.title = title
        self.artist = artist
        self.appleMusicURL = appleMusicURL
    }
}

extension AudioMatch {
    /// The picks to store once this match is folded into `picks`, or nil when the match changes
    /// nothing — the common case, and one that must stay a no-write.
    ///
    /// Two rules, and the second is the one that matters:
    ///
    /// - A pick that named a release but no artist gets this artist, provided the titles agree
    ///   on the same terms every other catalogue lookup is judged by.
    /// - A pick the model gave an artist keeps it. The sound playing over a video is not the
    ///   record the video recommends: a countdown of twelve albums matches exactly one track,
    ///   and letting that one match rewrite artists would invent eleven wrong ones.
    ///
    /// A `.music` video with no picks at all has nothing to contradict, so the match becomes its
    /// single pick — that is the entire answer for a "what song is this" save.
    public func merged(into picks: [MusicPick], category: Category) -> [MusicPick]? {
        // A match missing either half fills nothing and names nothing.
        guard !title.isEmpty, !artist.isEmpty else { return nil }

        guard !picks.isEmpty else {
            guard category == .music else { return nil }
            return [MusicPick(kind: .track, title: title, artist: artist,
                              link: appleMusicURL.flatMap {
                                  MusicPickResolver.songLink(for: $0.absoluteString)
                              })]
        }

        var merged = picks
        var changed = false
        for index in merged.indices where merged[index].artist.isEmpty {
            // The gate the catalogue lookups already use: shared words, not edit distance. The
            // pick's artist is empty by definition here, so this is the title threshold alone.
            guard MatchConfidence.accepts(askedTitle: merged[index].title, askedArtist: "",
                                          returnedTitle: title, returnedArtist: artist) else { continue }
            merged[index].artist = artist
            changed = true
        }
        // Nothing agreed: a track playing under an unrelated list is not a correction of it.
        guard changed else { return nil }
        // The stored list is capped where it is decoded; this is the only other way it grows.
        return Array(merged.prefix(MusicPick.maxPerVideo))
    }
}

/// ShazamKit over a local media file. Two windows, first match wins.
public struct ShazamResolver: AudioMatching {
    /// Shazam needs a few seconds of clean audio; fifteen survives a talking intro over the track.
    private static let window = 15.0

    public init() {}

    public func match(fileURL: URL) async -> AudioMatch? {
        let asset = AVURLAsset(url: fileURL)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }

        // Two windows because the start of a TikTok is usually the talking and the middle is
        // usually the drop. Anything short enough that the second would overlap the first is
        // sampled once, from the top.
        let starts: [Double] = seconds > Self.window * 2 ? [0, (seconds - Self.window) / 2] : [0]
        for start in starts {
            guard let signature = try? await Self.signature(of: asset, from: start),
                  case .match(let hit) = await SHSession().result(from: signature),
                  let item = hit.mediaItems.first,
                  let title = item.title, let artist = item.artist,
                  !title.isEmpty, !artist.isEmpty else { continue }
            return AudioMatch(title: title, artist: artist, appleMusicURL: item.appleMusicURL)
        }
        return nil
    }

    /// One window of the asset's audio as a Shazam signature, or nil when there is no audio to
    /// read. `AVAssetReader` rather than `SHSignatureGenerator.signature(from:)`: the whole-asset
    /// convenience decodes the entire track, and two fifteen-second windows are a fraction of it.
    private static func signature(of asset: AVURLAsset, from start: Double) async throws -> SHSignature? {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                       duration: CMTime(seconds: window, preferredTimescale: 600))
        // 44.1 kHz mono float: one of the four rates the generator accepts, and mixing the tracks
        // down to a single channel is what it does with them anyway.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                         channels: 1, interleaved: true) else { return nil }
        reader.add(output)
        reader.startReading()

        let generator = SHSignatureGenerator()
        var read = false
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = pcmBuffer(from: sample, format: format) else { continue }
            try generator.append(buffer, at: nil)
            read = true
        }
        // An empty generator signs silence, and silence matches nothing but costs a round trip.
        return read ? generator.signature() : nil
    }

    private static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
