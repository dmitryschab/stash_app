// PickFrames.swift
//
// A haul video's cover shows one moment; six picks came from six different ones. The frames
// were already in hand once — the visual pass samples twelve and OCRs them — and FrameReader
// stamps every text block with the frame it came from ("[7] BENQ SCREENBAR HALO 2 | €179").
// That stamp is the bridge: a pick's name finds its block, the block names its frame, and the
// frame's pixels become the pick's own picture instead of the video's cover.
//
// Matching is deliberately strict (`matchFloor`): a wrong picture on a pick page claims the
// wrong product, which is worse than falling back to the cover. Videos whose products never
// appear as on-screen text match nothing and keep the cover — the honest outcome, not a gap.

import Foundation

public enum PickFrames {

    // MARK: - Name → frame

    /// The share of a name's tokens a frame must carry. Three-quarters keeps "standing desk
    /// setup" from stealing "Grovemade Standing Desk" — generic words alone never clear it.
    static let matchFloor = 0.75

    /// The 0-based sampled-frame index whose OCR block best matches `name`, or nil when no
    /// block clears `matchFloor` — including all text stored before FrameReader grouped by
    /// frame, which carries no markers and therefore points at nothing.
    public static func frameIndex(for name: String, in groupedText: String?) -> Int? {
        guard let groupedText else { return nil }
        let wanted = tokens(in: name)
        guard !wanted.isEmpty else { return nil }

        var best: (frame: Int, score: Double)?
        for line in groupedText.split(separator: "\n") {
            guard let (frame, body) = frameBlock(String(line)) else { continue }
            let present = Set(tokens(in: body))
            let score = Double(wanted.filter(present.contains).count) / Double(wanted.count)
            if score >= matchFloor, score > (best?.score ?? 0) {
                best = (frame, score)
            }
        }
        return best?.frame
    }

    /// "[7] BENQ … " → (6, " BENQ … "). The number is the frame's position in the original
    /// sample, not the block's position in the text — FrameReader drops duplicate frames, so
    /// the two drift apart.
    private static func frameBlock(_ line: String) -> (Int, String)? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
              let number = Int(line[line.index(after: line.startIndex)..<close]), number >= 1
        else { return nil }
        return (number - 1, String(line[line.index(after: close)...]))
    }

    /// Lowercased, diacritic-folded, alphanumeric runs of 2+ — "Aesop® résurrection" and
    /// "AESOP RESURRECTION" tokenize identically, and stray single letters ("4", "i") never
    /// count toward a match either way.
    private static func tokens(in text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    // MARK: - Picture storage

    /// Beside the covers on purpose: account sign-out and the thumbnail wipe already clear
    /// that directory, and both pictures are derived from the same save the cover is.
    /// `directory` is a parameter only so tests can point it at scratch.
    public static func frameURL(videoID: String, pickIndex: Int,
                                directory: URL = ThumbnailStore.directory) -> URL {
        directory.appendingPathComponent("buy-\(videoID)-\(pickIndex).jpg")
    }

    /// The shop's catalog photo for the pick, fetched with its offers.
    public static func productImageURL(videoID: String, pickIndex: Int,
                                       directory: URL = ThumbnailStore.directory) -> URL {
        directory.appendingPathComponent("buy-\(videoID)-\(pickIndex)-product.jpg")
    }

    /// The pick's stored frame, or nil when it has not been extracted (or never matched).
    public static func cachedFrame(videoID: String, pickIndex: Int,
                                   directory: URL = ThumbnailStore.directory) -> URL? {
        existing(frameURL(videoID: videoID, pickIndex: pickIndex, directory: directory))
    }

    public static func cachedProductImage(videoID: String, pickIndex: Int,
                                          directory: URL = ThumbnailStore.directory) -> URL? {
        existing(productImageURL(videoID: videoID, pickIndex: pickIndex, directory: directory))
    }

    /// What a row draws for the pick: the catalog photo when the shop had one, else the video
    /// frame, else nil (and the caller falls back to the cover).
    public static func picture(videoID: String, pickIndex: Int,
                               directory: URL = ThumbnailStore.directory) -> URL? {
        cachedProductImage(videoID: videoID, pickIndex: pickIndex, directory: directory)
            ?? cachedFrame(videoID: videoID, pickIndex: pickIndex, directory: directory)
    }

    /// Downscales one sampled PNG into the pick's frame slot — same 640 px JPEG budget as a cover.
    @discardableResult
    public static func storeFrame(png: URL, videoID: String, pickIndex: Int,
                                  directory: URL = ThumbnailStore.directory) -> URL? {
        guard let data = try? Data(contentsOf: png) else { return nil }
        return store(data, at: frameURL(videoID: videoID, pickIndex: pickIndex, directory: directory))
    }

    /// Downscales downloaded image bytes into the pick's product slot. Bytes that are not an
    /// image (a shop's captcha page, say) store nothing.
    @discardableResult
    public static func storeProductImage(_ data: Data, videoID: String, pickIndex: Int,
                                         directory: URL = ThumbnailStore.directory) -> URL? {
        store(data, at: productImageURL(videoID: videoID, pickIndex: pickIndex, directory: directory))
    }

    private static func store(_ data: Data, at local: URL) -> URL? {
        guard let jpeg = ThumbnailStore.downscaled(data),
              (try? jpeg.write(to: local, options: .atomic)) != nil else { return nil }
        return local
    }

    private static func existing(_ local: URL) -> URL? {
        FileManager.default.fileExists(atPath: local.path) ? local : nil
    }
}
