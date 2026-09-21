import Foundation

/// Parses a TikTok "Download your data" export into `Bookmark`s.
///
/// The export JSON layout has changed across TikTok versions and uses both
/// "Favorite"/"Favourite" spellings, so parsing walks the whole tree and
/// collects every array whose key matches `(?i)favou?rite.*video` and whose
/// items are objects carrying `Date`/`date` and `Link`/`link` fields.
///
/// The zip TikTok hands over is read as it is: `parse(zipAt:)` takes the raw
/// archive, an already-extracted directory, or a single JSON file, so nobody
/// has to unpack anything first. `ZipReader` does the archive walk — see its
/// ceiling there — and every JSON member merges the way directory files do.
public struct ExportParser {
    public init() {}

    /// Parse bookmarks from raw export JSON data.
    public func parse(jsonData: Data) throws -> [Bookmark] {
        let root = try JSONSerialization.jsonObject(with: jsonData, options: [])
        return bookmarks(from: collectFavoriteItems(in: root))
    }

    /// Parse bookmarks from an export.
    ///
    /// - A directory is scanned (non-recursively) for `*.json` files, which are
    ///   parsed and merged.
    /// - A single `*.json` file is parsed directly.
    /// - A zip has its `*.json` members read and merged the same way; one that
    ///   cannot be read throws `CocoaError(.fileReadCorruptFile)`.
    /// - Any other file throws `CocoaError(.fileReadUnknown)`.
    public func parse(zipAt url: URL) throws -> [Bookmark] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileNoSuchFile)
        }

        if isDirectory.boolValue {
            var items: [[String: Any]] = []
            let contents = try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            for file in contents where file.pathExtension.lowercased() == "json" {
                let data = try Data(contentsOf: file)
                let root = try JSONSerialization.jsonObject(with: data, options: [])
                items.append(contentsOf: collectFavoriteItems(in: root))
            }
            return bookmarks(from: items)
        }

        if url.pathExtension.lowercased() == "json" {
            return try parse(jsonData: Data(contentsOf: url))
        }

        if url.pathExtension.lowercased() == "zip" || Self.startsWithZipMagic(url) {
            var items: [[String: Any]] = []
            for member in try ZipReader.jsonMembers(of: url) {
                let root = try JSONSerialization.jsonObject(with: member, options: [])
                items.append(contentsOf: collectFavoriteItems(in: root))
            }
            return bookmarks(from: items)
        }

        throw CocoaError(.fileReadUnknown)
    }

    /// The local file header magic every zip opens with, so an export that reached the picker
    /// without its extension — saved from Mail, renamed, handed over by another app — still reads.
    private static func startsWithZipMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: - Tree walk

    /// Recursively collect every favorite-video item object in the JSON tree.
    private func collectFavoriteItems(in root: Any) -> [[String: Any]] {
        var items: [[String: Any]] = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                for (key, value) in dict {
                    if keyMatchesFavoriteVideos(key), let array = value as? [Any] {
                        for element in array {
                            if let object = element as? [String: Any], hasDateAndLink(object) {
                                items.append(object)
                            }
                        }
                    }
                    walk(value)
                }
            } else if let array = node as? [Any] {
                for element in array { walk(element) }
            }
        }
        walk(root)
        return items
    }

    /// Implements `(?i)favou?rite.*video`: contains "favorite"/"favourite"
    /// followed later by "video", case-insensitively.
    private func keyMatchesFavoriteVideos(_ key: String) -> Bool {
        let lowered = key.lowercased()
        for spelling in ["favorite", "favourite"] {
            if let range = lowered.range(of: spelling),
               lowered[range.upperBound...].contains("video") {
                return true
            }
        }
        return false
    }

    private func hasDateAndLink(_ object: [String: Any]) -> Bool {
        dateString(object) != nil && linkString(object) != nil
    }

    private func dateString(_ object: [String: Any]) -> String? {
        (object["Date"] as? String) ?? (object["date"] as? String)
    }

    private func linkString(_ object: [String: Any]) -> String? {
        (object["Link"] as? String) ?? (object["link"] as? String)
    }

    // MARK: - Build & de-duplicate

    private func bookmarks(from items: [[String: Any]]) -> [Bookmark] {
        let formatter = Self.makeDateFormatter()
        var newestByID: [String: Bookmark] = [:]
        for object in items {
            guard let dateText = dateString(object),
                  let linkText = linkString(object),
                  let url = URL(string: linkText),
                  let date = formatter.date(from: dateText) else { continue }
            let bookmark = Bookmark(id: videoID(from: url), url: url, date: date)
            if let existing = newestByID[bookmark.id], existing.date >= bookmark.date {
                continue
            }
            newestByID[bookmark.id] = bookmark
        }
        return newestByID.values.sorted { $0.date > $1.date }
    }

    /// Video id = the last all-digit path component of the link, else the full URL string.
    private func videoID(from url: URL) -> String {
        let digitComponents = url.pathComponents.filter(Self.isAllDigits)
        return digitComponents.last ?? url.absoluteString
    }

    private static func isAllDigits(_ string: String) -> Bool {
        !string.isEmpty && string.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }
}
