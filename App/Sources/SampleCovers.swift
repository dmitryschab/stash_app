// SampleCovers.swift
//
// Cover art for the demo library. Its videos are invented, so there is no TikTok frame to
// fetch and oEmbed answers 400 for every one of them (see ThumbnailStore.backfill) — without
// this, every tile in Today, Library and Cook is the grey fallback, which reads as an app
// whose images are broken rather than a library that is openly demo content.
//
// ponytail: drawn on the device from the video id rather than bundled as 21 JPEGs — no assets
// to license, no bundle weight, no network, and stable across launches because the id is. The
// ceiling is that these are abstract, not video frames; bundling stills is the upgrade if the
// demo ever needs to look like real content.

import TikTokBrainKit
import UIKit

enum SampleCovers {
    /// Gives each sample video a generated cover and points it at the file. Videos that already
    /// have one cached are left alone, so a reseed does not redraw what is already on disk.
    static func draw(for videos: [Video]) {
        for video in videos {
            if let cached = ThumbnailStore.cached(videoID: video.videoID) {
                video.thumbnailURL = cached
            } else if let drawn = write(video) {
                video.thumbnailURL = drawn
            }
        }
    }

    private static let side: CGFloat = 640

    private static func write(_ video: Video) -> URL? {
        let size = CGSize(width: side, height: side)
        // Two stops a step apart on the wheel, so a wall of tiles reads as varied rather than
        // as one colour repeated; the hue is the id's hash, so it never moves between launches.
        let hue = CGFloat(fnv1a(video.videoID) % 360) / 360
        let near = UIColor(hue: hue, saturation: 0.50, brightness: 0.80, alpha: 1)
        let far = UIColor(hue: (hue + 0.11).truncatingRemainder(dividingBy: 1),
                          saturation: 0.72, brightness: 0.40, alpha: 1)

        let image = UIGraphicsImageRenderer(size: size).image { context in
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [near.cgColor, far.cgColor] as CFArray,
                locations: [0, 1]
            ) else { return }
            context.cgContext.drawLinearGradient(
                gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            drawGlyph(for: video, in: size)
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { return nil }
        let url = ThumbnailStore.directory.appendingPathComponent("\(video.videoID).jpg")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// The same symbol the fallback tile uses, so a generated cover and a real one sit in the
    /// same visual family. An unavailable sample has no category and gets the generic mark.
    private static func drawGlyph(for video: Video, in size: CGSize) {
        let name = video.category?.symbol ?? "play.rectangle.fill"
        let configuration = UIImage.SymbolConfiguration(pointSize: 250, weight: .semibold)
        guard let glyph = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(UIColor.white.withAlphaComponent(0.24), renderingMode: .alwaysOriginal)
        else { return }
        glyph.draw(at: CGPoint(x: (size.width - glyph.size.width) / 2,
                               y: (size.height - glyph.size.height) / 2))
    }

    /// FNV-1a rather than `hashValue`: Swift seeds its hasher per process, so the stock hash
    /// would repaint the whole demo library a different colour on every launch.
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
