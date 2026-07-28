// SharedInbox.swift
//
// The only thing the share extension and the app share: a directory in the app-group
// container holding one file per shared link.
//
// One file per link rather than one appended list, because the two writers are separate
// processes and a shared list is a read-modify-write race with no lock available. With a file
// each, the extension only ever creates and the app only ever reads-then-deletes, so the two
// never touch the same path and nothing has to be coordinated.

import Foundation

public struct SharedInbox: Sendable {
    /// Declared on both targets' entitlements; see App/project.yml.
    public static let appGroupID = "group.dev.dmitryschab.Stash"

    private let directory: URL

    /// Nil when the app-group container is unavailable — a provisioning failure, not a runtime
    /// condition. Callers treat it as "no inbox" rather than crashing the share sheet.
    public init?(appGroupID: String = SharedInbox.appGroupID) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else { return nil }
        self.init(directory: container.appendingPathComponent("pending", isDirectory: true))
    }

    /// Direct-directory initializer, for tests.
    public init(directory: URL) {
        self.directory = directory
    }

    @discardableResult
    public func write(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(Self.fileExtension)
        try Data(url.absoluteString.utf8).write(to: file, options: .atomic)
        return file
    }

    public var pendingCount: Int { files().count }

    /// Reads every pending file and deletes it, returning the links that parsed.
    ///
    /// A file that does not parse is deleted too: leaving it would jam every later share behind
    /// a link that can never succeed. The caller owns what happens next — a submission that
    /// fails is expected to `write` the links back, which is safe because ingestion de-duplicates
    /// on video id.
    public func drain() -> [URL] {
        files().compactMap { file in
            defer { try? FileManager.default.removeItem(at: file) }
            guard let data = try? Data(contentsOf: file) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text), url.scheme != nil, url.host != nil else { return nil }
            return url
        }
    }

    private static let fileExtension = "txt"

    /// Oldest first, so a run of shares reaches the library in the order they were made.
    private func files() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { $0.pathExtension == Self.fileExtension }
            .sorted { left, right in
                let leftDate = (try? left.resourceValues(forKeys: [.creationDateKey]).creationDate)
                let rightDate = (try? right.resourceValues(forKeys: [.creationDateKey]).creationDate)
                guard let leftDate, let rightDate, leftDate != rightDate else {
                    // Same-second writes (a rapid run of shares) fall back to the filename so the
                    // order is at least stable rather than whatever the directory enumerator gave.
                    return left.lastPathComponent < right.lastPathComponent
                }
                return leftDate < rightDate
            }
    }
}
