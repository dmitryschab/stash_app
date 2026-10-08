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
///
/// Instagram's export goes through the same door: a file named `saved_posts…json`
/// is read as Instagram saves instead (see `instagramSaves(in:)`).
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
            let contents = try fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return try bookmarks(fromFiles: try contents
                .filter { $0.pathExtension.lowercased() == "json" }
                .map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }

        if url.pathExtension.lowercased() == "json" {
            return try bookmarks(fromFiles: [(url.lastPathComponent, try Data(contentsOf: url))])
        }

        if url.pathExtension.lowercased() == "zip" || Self.startsWithZipMagic(url) {
            return try bookmarks(fromFiles: try ZipReader.jsonMembers(of: url))
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

    /// Every JSON file of an export, merged. A file is read as either TikTok's or Instagram's,
    /// never both, so one reel or favourite cannot arrive twice under two readings.
    private func bookmarks(fromFiles files: [(name: String, data: Data)]) throws -> [Bookmark] {
        var items: [[String: Any]] = []
        var instagram: [Bookmark] = []
        for file in files {
            let root = try JSONSerialization.jsonObject(with: file.data, options: [])
            let fileName = file.name.split(separator: "/").last.map(String.init) ?? file.name
            if fileName.lowercased().contains("saved_posts") {
                instagram.append(contentsOf: instagramSaves(in: root))
            } else {
                items.append(contentsOf: collectFavoriteItems(in: root))
            }
        }
        return newestPerID(bookmarks(from: items) + instagram)
    }

    // MARK: - Instagram

    /// Instagram's `saved_posts.json`, in both layouts Meta has shipped: the current top-level
    /// array of `{timestamp, label_values: [{label: "URL", href}, …]}`, and the older
    /// `{saved_saved_media: [{string_map_data: {"Saved on": {href, timestamp}}}]}`. The
    /// timestamp is the save, in Unix seconds.
    ///
    /// ponytail: reels only. `TikTokLink.videoID` refuses `/p/` links because a post can be a
    /// carousel the box's extractor cannot take, so saved photos and pre-reel video posts are
    /// skipped; reading them means teaching the box `/p/` first.
    private func instagramSaves(in root: Any) -> [Bookmark] {
        var saves: [(link: Any?, time: Any?)] = []
        if let entries = root as? [[String: Any]] {
            for entry in entries {
                let link = (entry["label_values"] as? [[String: Any]])?
                    .first { ($0["label"] as? String) == "URL" }
                saves.append((link?["href"] ?? link?["value"], entry["timestamp"]))
            }
        } else if let entries = (root as? [String: Any])?["saved_saved_media"] as? [[String: Any]] {
            for entry in entries {
                let saved = (entry["string_map_data"] as? [String: Any])?["Saved on"] as? [String: Any]
                saves.append((saved?["href"], saved?["timestamp"]))
            }
        }
        return saves.compactMap { link, time in
            guard let text = link as? String, let url = URL(string: text),
                  TikTokLink.isInstagram(url), let id = TikTokLink.videoID(in: url),
                  let seconds = (time as? NSNumber)?.doubleValue else { return nil }
            return Bookmark(id: id, url: TikTokLink.canonical(url),
                            date: Date(timeIntervalSince1970: seconds))
        }
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

    /// Not private: the TikTok sync's favourites (`TikTokConnectClient.sync`) come through
    /// here too, so a synced favourite and an exported one are the same `Bookmark`.
    func bookmarks(from items: [[String: Any]]) -> [Bookmark] {
        let formatter = Self.makeDateFormatter()
        return newestPerID(items.compactMap { object in
            guard let dateText = dateString(object),
                  let linkText = linkString(object),
                  let url = URL(string: linkText),
                  let date = formatter.date(from: dateText) else { return nil }
            return Bookmark(id: videoID(from: url), url: url, date: date)
        })
    }

    /// One bookmark per id, the most recent save winning, newest first.
    private func newestPerID(_ bookmarks: [Bookmark]) -> [Bookmark] {
        var newestByID: [String: Bookmark] = [:]
        for bookmark in bookmarks {
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
