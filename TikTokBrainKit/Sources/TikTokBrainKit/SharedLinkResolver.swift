// SharedLinkResolver.swift
//
// Deciding what happens to each link the share extension handed over.
//
// This is the one branch in the share path where getting it wrong loses a user's save without
// telling them: a link dropped because the network blinked is gone, and the only record it ever
// existed was the file that was just deleted. Kept out of `PipelineCenter` so it can be tested
// against a stub resolver rather than against TikTok.

import Foundation

public struct SharedLinkBatch: Sendable, Equatable {
    /// Resolved and ready to ingest and submit.
    public var bookmarks: [Bookmark]
    /// Worth another attempt — the caller writes these back to the inbox.
    public var requeue: [URL]
    /// Permanently unusable: not a TikTok, or a video that is gone. Reported, not retried.
    public var rejected: [TikTokLink.Failure]

    public init(bookmarks: [Bookmark] = [], requeue: [URL] = [], rejected: [TikTokLink.Failure] = []) {
        self.bookmarks = bookmarks
        self.requeue = requeue
        self.rejected = rejected
    }

    /// The message to show for whatever could not be saved, or nil when everything resolved.
    /// Names the first reason rather than listing all of them; the count carries the rest.
    public var rejectionMessage: String? {
        guard let first = rejected.first else { return nil }
        guard rejected.count > 1 else { return first.localizedDescription }
        return "\(first.localizedDescription) (\(rejected.count) shared links couldn't be opened)"
    }
}

public enum SharedLinkResolver {
    /// Resolves every link, sorting the failures into "try again later" and "never going to
    /// work". An error that is not a `TikTokLink.Failure` is treated as retryable: an unknown
    /// failure is not evidence that the video is gone, and holding a link costs nothing.
    public static func resolve(
        _ links: [URL],
        using resolve: (URL) async throws -> Bookmark
    ) async -> SharedLinkBatch {
        var batch = SharedLinkBatch()
        for link in links {
            do {
                batch.bookmarks.append(try await resolve(link))
            } catch let failure as TikTokLink.Failure where !failure.isRetryable {
                batch.rejected.append(failure)
            } catch {
                batch.requeue.append(link)
            }
        }
        return batch
    }
}
