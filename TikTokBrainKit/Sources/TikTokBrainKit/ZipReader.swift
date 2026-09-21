// ZipReader.swift
//
// Reading the export TikTok actually hands over.
//
// "Download your data" arrives as a zip, and the Import screen used to ask people to unpack it
// first — a step iOS Files does not make obvious. `Process`/`unzip` is unavailable on iOS and a
// zip library would be a new dependency, so the archive is walked here instead: the central
// directory says where each member lives, and Compression inflates the ones worth reading. The
// export's txt, csv and media members are skipped without ever being decompressed.

import Compression
import Foundation

/// Reads the JSON members of a zip without unpacking it to disk.
/// ponytail: no zip64, no encryption, whole member in memory and no larger than
/// `maxMemberBytes` — fine for TikTok exports (tens of MB); swap for a streaming reader if one
/// ever exceeds a few hundred MB.
enum ZipReader {
    private static let localHeaderSignature = 0x0403_4b50
    private static let centralHeaderSignature = 0x0201_4b50
    private static let endOfCentralDirectorySignature = 0x0605_4b50

    /// The most an End of Central Directory record can sit from the end of the file: its own
    /// 22 bytes plus the 65 535-byte comment that may follow it.
    private static let maxEndOfCentralDirectoryScan = 65_557

    /// The largest member the reader will hold. A central directory can promise any uncompressed
    /// size up to 4 GB, and nothing in a small file stops it lying: without this, a few hundred
    /// bytes of deflated zeros would reach `Data(count:)` and get the app jetsam-killed. 256 MB
    /// is an order of magnitude past the largest JSON a TikTok export has been seen to carry.
    private static let maxMemberBytes = 256 << 20

    /// Anything the reader cannot make sense of — truncated, encrypted, zip64, or compressed
    /// with a method we do not implement. One error for all of them: the caller's only move is
    /// to tell the person the file did not read.
    private static var corrupt: CocoaError { CocoaError(.fileReadCorruptFile) }

    static func jsonMembers(of url: URL) throws -> [Data] {
        let archive = try Data(contentsOf: url)
        let directory = try endOfCentralDirectory(in: archive)

        guard let entryCount = archive.le16(directory + 10),
              let firstEntry = archive.le32(directory + 16) else { throw corrupt }

        var members: [Data] = []
        var cursor = firstEntry
        for _ in 0..<entryCount {
            guard archive.le32(cursor) == centralHeaderSignature,
                  let flags = archive.le16(cursor + 8),
                  let method = archive.le16(cursor + 10),
                  let compressedSize = archive.le32(cursor + 20),
                  let uncompressedSize = archive.le32(cursor + 24),
                  let nameLength = archive.le16(cursor + 28),
                  let extraLength = archive.le16(cursor + 30),
                  let commentLength = archive.le16(cursor + 32),
                  let localHeader = archive.le32(cursor + 42),
                  let name = archive.string(at: cursor + 46, count: nameLength) else { throw corrupt }
            cursor += 46 + nameLength + extraLength + commentLength

            // Re-zipping an export on a Mac adds an AppleDouble sidecar per file, under
            // `__MACOSX/` and named `._<original>`. Those end in `.json` but hold resource-fork
            // binary, so reading one would fail the whole import over a file nobody asked for.
            let lastComponent = name.split(separator: "/").last ?? ""
            guard !name.hasSuffix("/"), name.lowercased().hasSuffix(".json"),
                  !name.hasPrefix("__MACOSX/"), !lastComponent.hasPrefix("._") else { continue }
            // Bit 0 of the general purpose flag is the (unsupported) traditional encryption; a
            // 0xFFFFFFFF size or offset means the real value lives in a zip64 extra field.
            guard flags & 1 == 0,
                  compressedSize != 0xFFFF_FFFF,
                  uncompressedSize != 0xFFFF_FFFF,
                  localHeader != 0xFFFF_FFFF else { throw corrupt }
            // Checked before either branch can allocate, so a lying size costs nothing. The
            // stored branch is covered too, though its size is pinned to the file by the
            // `compressedSize == uncompressedSize` check below.
            guard uncompressedSize <= maxMemberBytes else { throw corrupt }

            // Sizes and method come from the central directory, because an entry written from a
            // stream leaves them zeroed in the local header and in a data descriptor instead.
            // The local header is read only for its own name and extra lengths, which differ
            // from the central directory's and place the member's first byte.
            guard archive.le32(localHeader) == localHeaderSignature,
                  let localNameLength = archive.le16(localHeader + 26),
                  let localExtraLength = archive.le16(localHeader + 28) else { throw corrupt }
            let start = localHeader + 30 + localNameLength + localExtraLength
            guard start >= 0, compressedSize >= 0,
                  start + compressedSize <= archive.count else { throw corrupt }
            let payload = archive[start..<(start + compressedSize)]

            switch method {
            case 0:
                guard compressedSize == uncompressedSize else { throw corrupt }
                members.append(Data(payload))
            case 8:
                members.append(try inflate(payload, to: uncompressedSize))
            default:
                throw corrupt
            }
        }
        return members
    }

    /// The End of Central Directory record, found by scanning back from the end. The comment
    /// length is checked as well as the signature, so the same four bytes appearing inside a
    /// compressed member cannot be mistaken for the record.
    private static func endOfCentralDirectory(in archive: Data) throws -> Int {
        let limit = max(0, archive.count - maxEndOfCentralDirectoryScan)
        var offset = archive.count - 22
        while offset >= limit {
            if archive.le32(offset) == endOfCentralDirectorySignature,
               let commentLength = archive.le16(offset + 20),
               offset + 22 + commentLength == archive.count {
                return offset
            }
            offset -= 1
        }
        throw corrupt
    }

    /// Zip's method 8 is raw deflate, which is what `COMPRESSION_ZLIB` decodes. The destination
    /// is the size the central directory promised, so a short write means the member is damaged.
    private static func inflate(_ payload: Data, to size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source -> Int in
                guard let out = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let inp = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(
                    out, size, inp, payload.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw corrupt }
        return output
    }
}

/// Little-endian field reads that answer nil rather than trapping past the end of a truncated
/// archive, so every bounds check in the walk above is one `guard let`.
private extension Data {
    func le16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let base = index(startIndex, offsetBy: offset)
        return Int(self[base]) | Int(self[base + 1]) << 8
    }

    func le32(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = index(startIndex, offsetBy: offset)
        return Int(self[base]) | Int(self[base + 1]) << 8
            | Int(self[base + 2]) << 16 | Int(self[base + 3]) << 24
    }

    /// Member names are UTF-8 (or CP437, which agrees with UTF-8 for the ASCII TikTok uses).
    func string(at offset: Int, count length: Int) -> String? {
        guard offset >= 0, length >= 0, offset + length <= count else { return nil }
        let base = index(startIndex, offsetBy: offset)
        return String(decoding: self[base..<(base + length)], as: UTF8.self)
    }
}
