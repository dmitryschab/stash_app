// PipelineCenter.swift
//
// App-level owner of import processing. Previously the Import screen's private
// controller ran the pipeline, so processing appeared to live and die with that
// screen; now the loop belongs to the app and survives navigation, auto-resumes
// on foreground/launch, asks iOS for extra time when backgrounded mid-import,
// and registers a BGProcessingTask so idle/charging wakes continue the queue.
//
// Because those triggers are lifecycle-driven — the scenePhase watcher and a background
// wake both fire while the sign-in gate is still on screen — every entry point that starts
// work guards on `StashSession.shared.isSignedIn`. The bearer itself is never held here:
// clients ask `StashSession.authProvider` per request.

import BackgroundTasks
import Network
import SwiftData
import SwiftUI
import TikTokBrainKit
import UIKit
import UserNotifications

@MainActor
@Observable
final class PipelineCenter {
    static let shared = PipelineCenter()
    static let bgTaskID = "dev.dmitryschab.Stash.process"
    /// The library deep pass gets its own identifier because it gets its own conditions: this
    /// one asks iOS for external power, which the import task must never do — an import the
    /// user is watching cannot wait for a charger.
    static let deepPassTaskID = "dev.dmitryschab.Stash.deeppass"
    /// A light poll of the box while the app is closed mid-import, so "you can close the app"
    /// can end in a notification instead of a guess — and of the TikTok sync while one is
    /// connected (`syncTikTok`). App refresh, not processing: it wants no charger and takes seconds.
    static let refreshTaskID = "dev.dmitryschab.Stash.refresh"
    /// Set by the data guide when the user says they asked TikTok for the export; the empty
    /// states read it, and the next submitted import clears it.
    static let exportRequestedKey = "tiktokExportRequestedAt"

    var progress: (done: Int, total: Int)?
    /// What the library deep pass is reading right now, so the pill can say so instead of
    /// "Syncing" — which read as a re-import of a library that was already sorted.
    var deepPassReading: String?
    var isImporting = false
    var boxStatus: BoxStatus = .unknown
    var lastError: String?
    var lastSummary: String?
    var cloudStatus: CloudImportStatus?
    /// How many rows the library holds per category, split by whether an analysis has
    /// written them (`analysed`) or only Clef has (`guessed`, see `Video.isGuessed`). Refreshed
    /// after every batch of results or guesses on the poll's own context, so the views that
    /// draw skeletons read a dictionary instead of fetching the library per body.
    struct CategoryTally: Equatable { var analysed = 0; var guessed = 0 }
    private(set) var tallies: [Category: CategoryTally] = [:]
    var cloudSyncing = false
    /// A TikTok data request is out and the archive is not built yet; Settings says so under the
    /// connected row. Not persisted: every foreground asks the box again.
    private(set) var tiktokSyncWaiting = false
    private var tiktokSyncing = false
    /// Set when the shell's status pill is tapped; the Library reads it, pushes Import and clears
    /// it again. The pill and the Import screen have no other owner in common.
    var importRouteRequested = false
    /// The finished import the user has already waved away, so "N videos sorted" does not come
    /// back on the next launch. Loaded in `configure`, like the rest of the persisted state.
    private var dismissedImportID: String?
    /// The error message the user has already waved away. Every poll re-sets the same
    /// `lastError` — a dead session, a dead network — so clearing it alone put the pill back up
    /// seconds after the ✕. Deliberately not persisted: an error that survives a relaunch has
    /// earned the right to be said once more.
    private var dismissedError: String?

    /// A share surfaced to the UI from the moment the inbox is peeked until the fast pass
    /// classifies it (or the attempt fails) — what the Library's incoming card and the sync
    /// pill render during the otherwise silent resolve/submit window. Deliberately not
    /// persisted: the entries mirror the inbox files and the in-flight submission, both of
    /// which are re-derived on the next foreground.
    struct PendingShare: Identifiable, Equatable {
        enum Stage: Equatable { case fetching, saving, reading, failed(String) }
        let id: String              // inbox filename — exists before any video id does
        var stage: Stage = .fetching
        var videoIDs: [String] = []
    }

    var pendingShares: [PendingShare] = []
    /// Rows already ingested but still represented by the incoming card, so lists can
    /// avoid showing the same save twice.
    var pendingShareVideoIDs: Set<String> { Set(pendingShares.flatMap(\.videoIDs)) }

    var cloudImportEnabled: Bool { Self.cloudImportEnabled }

    private var container: ModelContainer?
    private var processingTask: Task<Void, Never>?
    private var cloudSyncTask: Task<Void, Never>?
    /// Held apart from `processingTask` so a foreground kick cannot drop the handle of a
    /// library pass that is already running — this one outlives the screen that started it.
    private var libraryDeepPassTask: Task<Void, Never>?
    private var extraTime: UIBackgroundTaskIdentifier = .invalid
    private var cloudState = CloudImportSyncState()
    /// The first status this session saw for the running import: where the ping's rate is
    /// measured from.
    private var firstPollSample: (importID: String, at: Date, done: Int)?
    private static let cloudStateKey = "cloudImport.syncState"

    /// A TikTok the share extension handed over, tracked until it is fully processed.
    ///
    /// `importID` is cleared once the box's fast pass has landed, but the entry itself only goes
    /// away after the transcript and on-screen-text passes have run — so a deep pass that could
    /// not start (app already importing, budget spent, network gone) is retried on the next
    /// foreground instead of being lost. `id` is the clientImportID, stable across retries.
    private struct ShareImport: Codable, Equatable {
        var id: UUID
        var importID: String?
        var videoIDs: [String]
    }

    private var shareImports: [ShareImport] = []
    private static let shareImportsKey = "sharedInbox.imports"
    /// Set when a deep pass gave up on a spent budget or a dead box. The poll loop runs every
    /// eight seconds, and without this it would re-attempt — and be refused — that often.
    /// Deliberately not persisted: the next foreground is exactly when retrying is worth it.
    private var deepPassBlocked = false

    // MARK: - Wiring

    /// Called once from the App with the shared SwiftData container.
    func configure(container: ModelContainer) {
        self.container = container
        if let data = UserDefaults.standard.data(forKey: Self.cloudStateKey),
           let state = try? JSONDecoder().decode(CloudImportSyncState.self, from: data) {
            cloudState = state
            cloudStatus = state.status
        }
        if let data = UserDefaults.standard.data(forKey: Self.shareImportsKey),
           let imports = try? JSONDecoder().decode([ShareImport].self, from: data) {
            shareImports = imports
        }
        dismissedImportID = UserDefaults.standard.string(forKey: Self.dismissedImportKey)
        Self.discardLegacyState()
        refreshTallies()   // a cold launch mid-import has skeletons to size
        MediaFetcher.sweepInterruptedReads()
        Self.startPowerAndPathWatch()
        refreshThumbnails()
    }

    // MARK: - Shell status

    private static let dismissedImportKey = "shellStatusDismissedImport"

    /// What the shell's one status pill says. Pure, so it can be checked without a pipeline.
    ///
    /// There used to be two channels and neither covered the common case: the pill read the
    /// on-device `progress` only, while the cloud import — the only Release path — reported on
    /// the Import screen alone, so a thousand-video import looked like nothing anywhere else.
    enum ShellStatus: Equatable {
        case reading                          // an export was picked; nothing submitted yet
        case syncing(done: Int, total: Int)   // on-device drain or the box's sorting pass
        case readingLibrary(String, done: Int, total: Int)  // the unasked-for deep pass: what it reads
        case shares(Int)                      // shared TikToks in flight
        case finished(sorted: Int)            // a finished import from the last 24 h, not dismissed
        case failed(String)                   // a failed share, or `lastError`
    }

    var shellStatus: ShellStatus? {
        Self.shellStatus(isImporting: isImporting, progress: progress, deepPass: deepPassReading,
                         cloud: cloudStatus, pendingShares: pendingShares, lastError: lastError,
                         dismissedError: dismissedError,
                         dismissedImportID: dismissedImportID, now: Date())
    }

    /// Clears what the pill is holding on to: the error it is showing — remembered as dismissed,
    /// because the poll that produced it will produce it again — and the placeholders of any
    /// share that died. Those outrank everything in `shellStatus`, so without this the ✕ would
    /// recompute straight back to the same caption.
    ///
    /// The finished import's id is recorded only when a finished import is what is on screen.
    /// Recording it on every dismissal meant waving away an error also buried the "N videos
    /// sorted" line the import had earned — the one moment the pill exists for.
    ///
    /// Dismissing loses nothing: a share whose failure is worth retrying was written back to the
    /// inbox before the caption went up, and the next foreground picks it up again with a fresh
    /// placeholder.
    func dismissShellStatus() {
        let dismissing = shellStatus
        // Only when there is one to remember: dismissing a finished import must not forget the
        // error that was waved away a minute ago.
        if let lastError { dismissedError = lastError }
        lastError = nil
        retireFailedShares()
        if case .finished = dismissing {
            dismissedImportID = cloudStatus?.importID
            UserDefaults.standard.set(dismissedImportID, forKey: Self.dismissedImportKey)
        }
    }

    /// The pill's whole decision as one function over values, first match wins: a share that died
    /// is louder than a sync still running, and a finished import is the quietest of all.
    static func shellStatus(isImporting: Bool, progress: (done: Int, total: Int)?,
                            deepPass: String? = nil, cloud: CloudImportStatus?, pendingShares: [PendingShare],
                            lastError: String?, dismissedError: String?,
                            dismissedImportID: String?, now: Date) -> ShellStatus? {
        // A failed share carries its own words (out of imports, signed out), so it must never be
        // painted over by a "Syncing" that is about some other piece of work.
        for share in pendingShares {
            if case .failed(let message) = share.stage { return .failed(message) }
        }
        if isImporting {
            if let progress, progress.total > 0 {
                if let deepPass { return .readingLibrary(deepPass, done: progress.done, total: progress.total) }
                return .syncing(done: progress.done, total: progress.total)
            }
            return .reading   // parsing the export: counted work has not started yet
        }
        if let cloud, cloud.state == .accepted || cloud.state == .fastPass {
            return .syncing(done: cloud.fastPass.done, total: cloud.fastPass.total)
        }
        if !pendingShares.isEmpty { return .shares(pendingShares.count) }
        // The same sentence, already waved away, stays away; a different one is news and shows.
        // Only this branch is suppressible — a failed share above carries its own words and was
        // never the thing that got dismissed.
        if let lastError, lastError != dismissedError { return .failed(lastError) }
        if let cloud, cloud.state == .completed,
           now.timeIntervalSince(cloud.updatedAt) < 86_400,
           cloud.importID != dismissedImportID {
            // Clamped like `notifyLibraryReady`: an import that resolved nothing must not read
            // as a negative count.
            return .finished(sorted: max(0, cloud.fastPass.done - cloud.unavailable))
        }
        return nil
    }

    // MARK: - Library map

    /// True while an import is running and its map has at least one answer — the window in
    /// which skeletons and the picker exist.
    var isShapingLibrary: Bool {
        #if DEBUG
        if Self.debugSorting != nil { return true }
        #endif
        guard let status = cloudStatus, status.state == .accepted || status.state == .fastPass,
              let map = status.map else { return false }
        return map.done > 0
    }

    /// The map's counts scaled to the import's total, largest first: what the picker's chips
    /// and the Import hero's bar show.
    var mapShares: [(category: Category, count: Int)] {
        guard isShapingLibrary, let status = cloudStatus, let map = status.map else { return [] }
        return map.counts
            .map { (category: $0.key, count: Self.scaled(count: $0.value, done: map.done, total: status.fastPass.total)) }
            .filter { $0.count > 0 }
            .sorted { ($0.count, $1.category.rawValue) > ($1.count, $0.category.rawValue) }
    }

    /// Skeleton rows still owed to `category`: the sample's share scaled to the import, minus
    /// every row already carrying that category (analysed or guessed). Zero outside an import.
    func expected(_ category: Category) -> Int {
        #if DEBUG
        if let forced = Self.debugSorting { return forced }
        #endif
        guard isShapingLibrary, let status = cloudStatus, let map = status.map else { return 0 }
        let tally = tallies[category] ?? CategoryTally()
        return Self.expected(count: map.counts[category] ?? 0, done: map.done,
                             total: status.fastPass.total, landed: tally.analysed + tally.guessed)
    }

    /// The same, per desk shelf: every category whose saves file under `intent` when nothing
    /// but the category is known — which is all a guessed row has.
    func expected(_ intent: SaveIntent, includeBuy: Bool) -> Int {
        librarySegments
            .filter { SaveIntent.classify(category: $0, topics: [], hasBuys: false, includeBuy: includeBuy) == intent }
            .reduce(0) { $0 + expected($1) }
    }

    static func scaled(count: Int, done: Int, total: Int) -> Int {
        guard done > 0, total > 0 else { return 0 }
        return Int((Double(count) / Double(done) * Double(total)).rounded())
    }

    static func expected(count: Int, done: Int, total: Int, landed: Int) -> Int {
        max(0, scaled(count: count, done: done, total: total) - landed)
    }

    #if DEBUG
    /// `-debugSorting 12` draws twelve skeletons under every category, with no import running
    /// — the only way to screenshot a shelf mid-sort from a seeded simulator.
    static let debugSorting: Int? = UserDefaults.standard.string(forKey: "debugSorting").flatMap(Int.init)

    /// The skeleton arithmetic, checked at launch like the pill's: it is a ratio of three
    /// numbers from two different sources and a clamp, none of it visible from any one screen.
    static func expectedSelfTest() -> Bool {
        expected(count: 30, done: 50, total: 1000, landed: 100) == 500
            && expected(count: 20, done: 50, total: 1000, landed: 450) == 0        // clamped
            && expected(count: 0, done: 50, total: 1000, landed: 0) == 0
            && expected(count: 30, done: 0, total: 1000, landed: 0) == 0           // nothing settled yet
            && expected(count: 30, done: 50, total: 0, landed: 0) == 0             // nothing to scale to
            && expected(count: 1, done: 3, total: 10, landed: 0) == 3              // rounds, not truncates
    }
    #endif

    /// Recount the library by category on a detached context, then publish.
    private func refreshTallies() {
        guard let container else { return }
        Task.detached(priority: .utility) { [weak self] in
            let context = ModelContext(container)
            guard let videos = try? context.fetch(FetchDescriptor<Video>()) else { return }
            var tallies: [Category: CategoryTally] = [:]
            for video in videos where !video.unavailable {
                guard let category = Category(rawValue: video.categoryRaw) else { continue }
                if video.isGuessed { tallies[category, default: CategoryTally()].guessed += 1 }
                else { tallies[category, default: CategoryTally()].analysed += 1 }
            }
            await MainActor.run { self?.tallies = tallies }
        }
    }

    private static func applyGuesses(_ guesses: [String: Category], to container: ModelContainer) async throws -> Int {
        try await Task.detached(priority: .utility) {
            try CloudImportResultUpserter.applyGuesses(guesses, to: ModelContext(container))
        }.value
    }

    #if DEBUG
    /// The order of precedence above is not visible from any single call site, and the pill is
    /// the only place most of these states are ever seen, so the table gets checked on launch.
    static func shellStatusSelfTest() -> Bool {
        let now = Date()
        func box(_ state: CloudImportState, _ done: Int, _ total: Int, unavailable: Int = 0,
                 ago: TimeInterval = 0, id: String = "imp-1") -> CloudImportStatus {
            CloudImportStatus(importID: id, state: state,
                              fastPass: CloudImportProgress(done: done, total: total),
                              unavailable: unavailable, partialFailures: 0, estimatedCostUSD: 0,
                              updatedAt: now.addingTimeInterval(-ago))
        }
        func pill(importing: Bool = false, progress: (done: Int, total: Int)? = nil,
                  deepPass: String? = nil, cloud: CloudImportStatus? = nil, shares: [PendingShare] = [],
                  error: String? = nil, dismissedError: String? = nil,
                  dismissed: String? = nil) -> ShellStatus? {
            Self.shellStatus(isImporting: importing, progress: progress, deepPass: deepPass,
                             cloud: cloud, pendingShares: shares, lastError: error,
                             dismissedError: dismissedError,
                             dismissedImportID: dismissed, now: now)
        }
        let finished = box(.completed, 941, 941, unavailable: 12, ago: 3_600)
        return pill() == nil
            && pill(importing: true) == .reading
            && pill(importing: true, progress: (3, 40)) == .syncing(done: 3, total: 40)
            && pill(importing: true, progress: (0, 959), deepPass: "Transcripts")
                == .readingLibrary("Transcripts", done: 0, total: 959)
            && pill(cloud: box(.fastPass, 412, 941)) == .syncing(done: 412, total: 941)
            && pill(cloud: box(.accepted, 0, 941)) == .syncing(done: 0, total: 941)
            && pill(shares: [PendingShare(id: "a"), PendingShare(id: "b")]) == .shares(2)
            // What `dismissShellStatus` leaves behind once it has retired the failed placeholder:
            // a share still in flight keeps the pill, and it must not read as a failure again.
            && pill(shares: [PendingShare(id: "b", stage: .reading)]) == .shares(1)
            && pill(cloud: finished) == .finished(sorted: 929)
            && pill(cloud: box(.completed, 941, 941, unavailable: 12, ago: 25 * 3_600)) == nil
            && pill(cloud: finished, dismissed: "imp-1") == nil
            && pill(importing: true, progress: (3, 40),
                    shares: [PendingShare(id: "share.json", stage: .failed("Out of imports"))])
                == .failed("Out of imports")
            && pill(error: "Could not reach the box.") == .failed("Could not reach the box.")
            // What the ✕ buys: the sentence the poll keeps re-setting stays down, and anything
            // it has not said before still gets through.
            && pill(error: "Your session expired.", dismissedError: "Your session expired.") == nil
            && pill(error: "You're offline.", dismissedError: "Your session expired.")
                == .failed("You're offline.")
            // A dead share is never what was dismissed — it outranks the error branch entirely.
            && pill(shares: [PendingShare(id: "share.json", stage: .failed("Out of imports"))],
                    error: "Out of imports", dismissedError: "Out of imports")
                == .failed("Out of imports")
            // And a dismissed error does not take the finished import down with it (I1's other half).
            && pill(cloud: finished, error: "You're offline.", dismissedError: "You're offline.")
                == .finished(sorted: 929)
    }
    #endif

    // MARK: - Cover art

    private var thumbnailTask: Task<Void, Never>?
    /// A refresh asked for while one was already running; the in-flight pass fetched its work
    /// list before those videos landed, so it would miss them.
    private var thumbnailsPending = false

    /// Fills in any missing cover art, then leaves it alone. Fire and forget: TikTok cover URLs
    /// expire within hours, so the picture has to come from bytes on disk, and the app is the
    /// only place that knows a video is still missing them.
    func refreshThumbnails() {
        guard let container else { return }
        guard thumbnailTask == nil else {
            thumbnailsPending = true
            return
        }
        thumbnailTask = Task { [weak self] in
            await ThumbnailStore.backfill(container: container)
            guard let self else { return }
            thumbnailTask = nil
            if thumbnailsPending {
                thumbnailsPending = false
                refreshThumbnails()
            }
        }
    }

    // MARK: - Search vectors

    private var embeddingTask: Task<Void, Never>?
    /// A pass asked for while one was already running; the in-flight run fetched its work list
    /// before those saves landed, so it would miss them. Same problem as `thumbnailsPending`.
    private var embeddingsPending = false

    /// Fills in the search vectors for saves that have none, then leaves them alone.
    ///
    /// Called wherever an analysis lands and on every foreground, because this is the cheapest
    /// drain here — no video download, no quota, one box call per 32 saves — so it needs none of
    /// the deep pass's charger-and-Wi-Fi gate. Fire and forget, like `refreshThumbnails`.
    ///
    /// ponytail: a save re-analyzed after it was embedded keeps its old vector until
    /// `BoxEmbeddingClient.revision` is bumped. The vector is built from the title, topics and
    /// summary, which a re-read rarely moves far, and invalidating on every deep-pass write would
    /// mean embedding the whole library twice over a difference nobody would see in the ranking.
    func backfillEmbeddings() {
        guard StashSession.shared.isSignedIn, let container else { return }
        guard embeddingTask == nil else {
            embeddingsPending = true
            return
        }
        let embedder = BoxEmbeddingClient(config: Self.currentConfig())
        embeddingTask = Task { [weak self] in
            await EmbeddingBackfill(container: container, embedder: embedder).run()
            guard let self else { return }
            embeddingTask = nil
            if embeddingsPending {
                embeddingsPending = false
                backfillEmbeddings()
            }
        }
    }

    /// Shop answers for picks that have none, so a pick page opens with its links already
    /// there. Fire and forget from the same places as `backfillEmbeddings`; `OfferStore`
    /// owns the order, the width and the stop rules.
    func backfillOffers() {
        guard StashSession.shared.isSignedIn, let container else { return }
        OfferStore.shared.prefetchLibrary(container: container)
    }

    /// Housekeeping for installs upgrading from build ≤13, which shipped a shared bearer in
    /// UserDefaults and could keep video files on the device. Both are gone by design now
    /// (per-user JWT in the Keychain; no persistent copies), so leaving the old ones lying
    /// around would be leaving a live credential and someone else's video behind.
    private static func discardLegacyState() {
        UserDefaults.standard.removeObject(forKey: "boxApiKey")
        let offlineVideos = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OfflineVideos", isDirectory: true)
        try? FileManager.default.removeItem(at: offlineVideos)
    }

    /// Cloud import is the default everywhere: pressing Import hands the whole library
    /// to the box, which processes it in the background whether or not the app stays
    /// open. Debug builds can force the on-device pipeline for local-box work.
    static var cloudImportEnabled: Bool {
        #if DEBUG
        !UserDefaults.standard.bool(forKey: CloudImportFeatureFlag.forceLocalKey)
        #else
        true
        #endif
    }

    /// Box config from the same defaults the Settings screen writes. The bearer is not part of
    /// it: `StashSession.authProvider` is asked per request, so a token refreshed mid-drain
    /// reaches every client already holding this config.
    static func currentConfig() -> BoxConfig {
        let defaults = UserDefaults.standard
        return makeBoxConfig(
            baseURL: defaults.string(forKey: "boxBaseURL") ?? BoxDefaults.baseURL,
            chatModel: defaults.string(forKey: "chatModel") ?? BoxDefaults.chatModel,
            whisperModel: defaults.string(forKey: "whisperModel") ?? BoxDefaults.whisperModel)
    }

    private func makeRunner() -> PipelineRunner? {
        guard let container else { return nil }
        return PipelineRunner(deps: Self.makeDeps(config: Self.currentConfig()), container: container)
    }

    /// The cloud-import API lives under the same base URL and behind the same per-user JWT as
    /// the rest of `/v1`, so no separate configuration is needed — Settings can still override
    /// the base URL for local-box development.
    private static func makeCloudClient() -> CloudImportClient? {
        guard let baseURL = URL(string: UserDefaults.standard.string(forKey: "boxBaseURL") ?? BoxDefaults.baseURL) else { return nil }
        return CloudImportClient(baseURL: baseURL, auth: StashSession.authProvider)
    }

    /// Builds the pipeline from the Kit's concrete clients. Shared with the per-video re-run.
    static func makeDeps(config: BoxConfig) -> PipelineDeps {
        PipelineDeps(
            enricher: Enricher(),
            media: MediaFetcher(),
            transcriber: TranscriberClient(config: config),
            analyzer: AnalyzerClient(config: config),
            musicResolver: MusicPickResolver(),
            ocr: { try await FrameReader().recognizeText(in: $0) }
        )
    }

    // MARK: - Import + resume

    /// Fresh import from a picked export file/folder. Cloud submits the whole library to
    /// the box (background processing); the on-device drain is the debug-only fallback.
    func runImport(url: URL) async {
        if Self.cloudImportEnabled {
            await runCloudImport(url: url)
        } else {
            await runLocalImport(url: url)
        }
    }

    /// Reads the picked export, off this actor.
    ///
    /// One entry point on purpose: `parse(zipAt:)` sorts out a folder, a .json, a .zip and raw
    /// zip magic bytes. Routing on `hasDirectoryPath` handed every picked .zip to
    /// JSONSerialization — and the .zip is the file people actually have.
    ///
    /// Detached because it is seconds of archive walking and JSON decoding for a big export, and
    /// on the main actor those seconds came straight out of the run loop: "Reading your export…"
    /// was assigned and then never painted, so the pill and the disabled button both arrived
    /// after the work they were describing had finished. Only `url` crosses over; the parser is
    /// built on the other side.
    private static func parseExport(at url: URL) async throws -> [Bookmark] {
        try await Task.detached(priority: .userInitiated) {
            try ExportParser().parse(zipAt: url)
        }.value
    }

    private func runLocalImport(url: URL) async {
        dismissedError = nil   // a new import is a new chance to be told what went wrong
        guard !isImporting, let runner = makeRunner() else { return }
        lastError = nil

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let bookmarks: [Bookmark]
        do {
            bookmarks = try await Self.parseExport(at: url)
        } catch {
            lastError = "Could not read the export: \(error.localizedDescription)"
            return
        }

        let newCount: Int
        do {
            newCount = try await runner.ingest(bookmarks: bookmarks)
        } catch {
            lastError = "Could not save bookmarks: \(error.localizedDescription)"
            return
        }
        lastSummary = "Imported \(bookmarks.count) bookmarks · \(newCount) new"

        await drainQueue(runner: runner)
    }

    private func runCloudImport(url: URL) async {
        dismissedError = nil   // a new import is a new chance to be told what went wrong
        guard !isImporting, let runner = makeRunner(), let client = Self.makeCloudClient() else {
            lastError = "Stash isn't configured — check the base URL in Settings."
            return
        }
        lastError = nil
        // Parsing, the quota call and up to 1200 inserts all happen before anything is submitted,
        // and the flag used to be claimed only afterwards — so for those seconds nothing moved
        // and the button stayed tappable. Claim it on the way in; the defer covers every exit.
        isImporting = true
        // Six exits below set `lastError` and return, and the Import card renders the error and
        // the summary independently — so without this the reading line sits under the error for
        // good. Keyed on the submit rather than on `lastError`, because the poll that follows a
        // good submit can set an error of its own and must not take the summary down with it.
        var submitted = false
        defer {
            isImporting = false
            if !submitted { lastSummary = nil }
        }
        lastSummary = "Reading your export…"

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let bookmarks: [Bookmark]
        do {
            bookmarks = try await Self.parseExport(at: url)
        } catch {
            lastError = "Could not read the export: \(error.localizedDescription)"
            return
        }

        guard !bookmarks.isEmpty else {
            // Names the cause that actually produces this: TXT was picked two days ago, and the
            // old wording sent people looking for the mistake in their favourites instead.
            lastError = "No favourites found. If you chose TXT when you asked TikTok for the "
                + "export, ask again with the format set to JSON."
            return
        }
        submitted = await submitCloudImport(bookmarks, runner: runner, client: client)
    }

    /// The half of an import that starts once the bookmarks are known: a picked export's, or the
    /// favourites a TikTok sync brought (`importSynced`). Ingests, submits what the budget covers
    /// and starts the poll. The caller holds `isImporting`. Returns whether the box accepted it.
    private func submitCloudImport(_ bookmarks: [Bookmark], runner: PipelineRunner,
                                   client: CloudImportClient) async -> Bool {
        guard bookmarks.count <= CloudImportLimits.maxVideosPerImport else {
            lastError = CloudImportError.tooManyVideos(bookmarks.count).localizedDescription
            return false
        }

        // The box charges one unit per submitted video and refuses an over-budget request
        // whole (cloud_import_store._write_quota), and the largest budget anyone can hold is
        // 600 — so a bigger library used to 402 forever, under an "Import budget used up"
        // message for a budget nothing had been spent from. Send the newest slice that fits.
        // ponytail: no per-video ledger, so importing again after the month turns over
        // re-submits the newest videos rather than the tail. The honest ceiling is a ~600-video
        // library; above that the summary says what went and what did not.
        await StashSession.shared.refreshQuota()  // the counter decides the slice — make it fresh
        let quota = StashSession.shared.quota
        let budget = quota?.remaining ?? CloudImportLimits.maxVideosPerImport
        let submitting = Array(bookmarks.sorted { $0.date > $1.date }.prefix(max(budget, 0)))
        guard !submitting.isEmpty else {
            // Only reachable with a known, spent budget: an unknown one submits and lets the
            // box be the judge.
            lastError = quota.map { StashError.quotaExhausted($0).localizedDescription }
                ?? StashError.unauthenticated.localizedDescription
            return false
        }

        do {
            let newCount = try await runner.ingest(bookmarks: bookmarks)
            let fingerprint = CloudImportSyncState.fingerprint(of: submitting)
            let clientImportID: UUID
            if cloudState.videoIDsFingerprint == fingerprint,
               let existing = cloudState.clientImportID,
               cloudState.importID == nil || cloudState.isActive {
                clientImportID = existing
            } else {
                clientImportID = UUID()
                cloudState = CloudImportSyncState(clientImportID: clientImportID)
            }
            cloudState.videoIDsFingerprint = fingerprint
            persistCloudState()
            let submission = try await client.submit(bookmarks: submitting, clientImportID: clientImportID)
            cloudState.importID = submission.importID
            persistCloudState()
            UserDefaults.standard.removeObject(forKey: Self.exportRequestedKey)
            cancelExportReminders()   // the export is in — stop nagging about downloading it
            // Asked here, where the answer buys something visible: the "library is ready" ping.
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            if submitting.count < bookmarks.count, let quota {
                let refills = quota.monthResetDate.formatted(date: .abbreviated, time: .omitted)
                lastSummary = "Submitted the newest \(submission.accepted) of \(bookmarks.count) "
                    + "· that is the whole budget · \(quota.monthLimit) more on \(refills)"
            } else {
                lastSummary = "Submitted \(submission.accepted) videos · \(newCount) new"
            }
            await syncCloudImport()
            return true
        } catch let error as StashError {
            // Quota and session failures already read as sentences; prefixing them would not help.
            lastError = error.localizedDescription
        } catch {
            var message = "Could not send your import: \(error.localizedDescription)"
            if let cloudError = error as? CloudImportError, cloudError.isRetryable { message += " Will retry automatically." }
            lastError = message
        }
        return false
    }

    /// Continues whatever is pending or parked — no file pick needed. Safe to call
    /// on every foreground/launch; does nothing when idle or already running.
    func resumePendingIfNeeded() {
        guard StashSession.shared.isSignedIn else { return }
        guard !Self.cloudImportEnabled else {
            syncCloudImportIfNeeded()
            return
        }
        guard !isImporting, let runner = makeRunner() else { return }
        processingTask = Task { [weak self] in
            let pending = (try? await runner.pendingCount()) ?? 0
            guard pending > 0 else { return }
            await self?.drainQueue(runner: runner)
        }
    }

    private func drainQueue(runner: PipelineRunner) async {
        isImporting = true
        UIApplication.shared.isIdleTimerDisabled = true  // big imports outlive auto-lock
        defer {
            isImporting = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        progress = try? await runner.processedCounts()
        await runner.processAll { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }
    }

    // MARK: - Export reminders

    private static let exportReminderIDs = ["export-reminder-1h", "export-reminder-24h"]

    /// TikTok takes anywhere from an hour to a couple of days to build an export, and nothing
    /// tells you when it lands — "I've requested it" used to schedule nothing at all, leaving
    /// the whole wait to the user's memory. Idempotent: calling it again just restarts the pair.
    func scheduleExportReminders() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Self.exportReminderIDs)
        Task {
            // Same ask `notifyLibraryReady` depends on, moved to the first moment it buys
            // something; an unauthorized center drops the requests silently.
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            for (identifier, delay) in zip(Self.exportReminderIDs, [3_600.0, 86_400.0]) {
                let content = UNMutableNotificationContent()
                content.title = "Your TikTok export may be ready"
                content.body = "Download it from TikTok and bring it into Stash."
                content.sound = .default
                try? await center.add(UNNotificationRequest(
                    identifier: identifier, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
            }
        }
    }

    func cancelExportReminders() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: Self.exportReminderIDs)
    }

    // MARK: - Shared links (share extension)

    /// Picks up whatever the share extension left in the app group. Safe to call on every
    /// foreground: an empty inbox costs one directory listing.
    ///
    /// Nothing is read unless the import can actually be attempted. Those files are the only
    /// record that the share ever happened, so a signed-out or already-busy app leaves them
    /// where they are rather than draining them onto the floor.
    func drainSharedInbox() {
        guard StashSession.shared.isSignedIn, Self.cloudImportEnabled, !isImporting else { return }
        guard let inbox = SharedInbox(), inbox.pendingCount > 0 else { return }
        // The placeholder exists before any network: peeking is a directory read, and these
        // entries are what the Library renders during the resolve and submit round trips.
        for entry in inbox.peek() where !pendingShares.contains(where: { $0.id == entry.id }) {
            pendingShares.append(PendingShare(id: entry.id))
        }
        processingTask = Task { [weak self] in
            await self?.importShared(links: inbox.drain(), returningTo: inbox)
        }
    }

    /// Resolves each shared link to a canonical video id and submits them as one cloud import.
    ///
    /// Anything that could work on a second attempt goes back into the inbox — a link TikTok was
    /// unreachable for, and every link in a submission that failed. `ingest` de-duplicates on
    /// video id, so a retry reuses the rows already inserted instead of doubling them.
    private func importShared(links: [URL], returningTo inbox: SharedInbox) async {
        guard !links.isEmpty else { return }
        guard let runner = makeRunner(), let client = Self.makeCloudClient() else {
            links.forEach { _ = try? inbox.write($0) }
            pendingShares.removeAll()
            lastError = "Stash isn't configured — check the base URL in Settings."
            return
        }
        isImporting = true
        defer { isImporting = false }
        lastError = nil

        let batch = await SharedLinkResolver.resolve(links) { try await TikTokLink.resolve($0) }
        batch.requeue.forEach { _ = try? inbox.write($0) }
        lastError = batch.rejectionMessage
        let bookmarks = batch.bookmarks
        guard !bookmarks.isEmpty else {
            failPendingShares()
            return
        }
        setPendingShares(stage: .saving)

        // The counter the box charges against; one unit per video here, as with any import.
        await StashSession.shared.refreshQuota()
        let clientImportID = UUID()
        do {
            _ = try await runner.ingest(bookmarks: bookmarks)
            let submission = try await client.submit(bookmarks: bookmarks, clientImportID: clientImportID)
            shareImports.append(ShareImport(
                id: clientImportID, importID: submission.importID, videoIDs: bookmarks.map(\.id)))
            persistShareImports()
            setPendingShares(stage: .reading, videoIDs: bookmarks.map(\.id))
            lastSummary = bookmarks.count == 1
                ? "Saved a shared TikTok — reading it now"
                : "Saved \(bookmarks.count) shared TikToks — reading them now"
            syncCloudImportIfNeeded()
        } catch {
            bookmarks.forEach { _ = try? inbox.write($0.url) }
            if let stashError = error as? StashError {
                // Out of budget (or signed out) is a state, not a glitch — say so on the
                // card itself and hold it long enough to read, or the share just looks broken.
                failPendingShares(message: stashError.localizedDescription, holdSeconds: 8)
                lastError = stashError.localizedDescription
            } else {
                failPendingShares()
                lastError = "Could not save the shared TikTok: \(error.localizedDescription)"
                    + " Will try again."
            }
        }
    }

    /// The reason share import exists at all: the box's fast pass classifies from the caption,
    /// and what a TikTok is actually about is usually spoken or burned into the frames. Once the
    /// fast pass has landed, fetch the transcript and read the on-screen text for exactly those
    /// videos — each pass re-analyzes with what it found.
    private func startDeepPassIfReady() {
        let ready = shareImports.filter { $0.importID == nil }
        guard !ready.isEmpty, !isImporting, !deepPassBlocked, let runner = makeRunner() else { return }
        let ids = Set(ready.map(\.id))
        let videoIDs = Set(ready.flatMap(\.videoIDs))
        let read = Self.makeDeepPassReader()
        processingTask = Task { [weak self] in
            await self?.drainDeepPass(runner: runner, shares: ids, videoIDs: videoIDs, read: read)
        }
    }

    private func drainDeepPass(
        runner: PipelineRunner,
        shares: Set<UUID>,
        videoIDs: Set<String>,
        read: @escaping @Sendable (String, URL) async throws -> DeepPass
    ) async {
        isImporting = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isImporting = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let transcripts = await runner.backfillTranscripts(only: videoIDs) { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }
        let visual = await runner.backfillVisualText(only: videoIDs, deepPass: read) { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }

        if let quota = transcripts.quotaExhausted ?? visual.quotaExhausted {
            // The save itself is safe — only the deep read is missing. Keep the entries so the
            // next foreground after the budget refills finishes the job.
            deepPassBlocked = true
            lastError = "Import budget used up — the shared TikTok is saved, but its transcript "
                + "and on-screen text are not. \(quota.monthLimit) more on "
                + quota.monthResetDate.formatted(date: .abbreviated, time: .omitted) + "."
            return
        }
        guard !transcripts.stoppedEarly, !visual.stoppedEarly else {
            deepPassBlocked = true
            lastError = "Stopped part-way through reading the shared TikTok — Stash will finish "
                + "it next time you open the app."
            return
        }
        shareImports.removeAll { shares.contains($0.id) }
        persistShareImports()
        lastSummary = "Shared TikTok ready · \(transcripts.filled) transcribed · "
            + "\(visual.filled) read on screen"
    }

    /// Advances every in-flight placeholder together: a share batch is one submission, so
    /// its card moves through the stages as one.
    private func setPendingShares(stage: PendingShare.Stage, videoIDs: [String]? = nil) {
        for index in pendingShares.indices {
            pendingShares[index].stage = stage
            if let videoIDs { pendingShares[index].videoIDs = videoIDs }
        }
    }

    /// Flips the placeholders to their failure caption, then clears them a beat later — the
    /// inbox files remain the durable record of the share, so the card only has to say what
    /// happened before getting out of the way.
    private func failPendingShares(message: String = "Couldn't sync — will retry",
                                   holdSeconds: UInt64 = 4) {
        guard !pendingShares.isEmpty else { return }
        setPendingShares(stage: .failed(message))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: holdSeconds * 1_000_000_000)
            self?.retireFailedShares()
        }
    }

    /// Drops the placeholders that are showing a failure, leaving anything still in flight alone.
    /// One definition for both ways a failure caption goes away: the hold above running out, and
    /// the user dismissing the shell's pill before it does.
    private func retireFailedShares() {
        pendingShares.removeAll { if case .failed = $0.stage { true } else { false } }
    }

    private func persistShareImports() {
        if let data = try? JSONEncoder().encode(shareImports) {
            UserDefaults.standard.set(data, forKey: Self.shareImportsKey)
        }
    }

    // MARK: - Library deep pass

    /// The same two backfills a shared save gets, aimed at the whole library instead of at one
    /// submission. Without it a bulk import stays caption-only forever: the fast pass classifies
    /// from the caption, and what a TikTok is actually about is usually spoken or burned into
    /// the frames — the deep pass was simply never pointed at anything but shares.
    ///
    /// Safe to call on every foreground: a closed gate costs one battery read and one path read.
    func startLibraryDeepPassIfReady() {
        guard libraryDeepPassTask == nil else { return }
        libraryDeepPassTask = Task { [weak self] in
            await self?.runLibraryDeepPass()
            self?.libraryDeepPassTask = nil
        }
    }

    /// Transcripts first, then visual text — the same order, the same serial pacing and the same
    /// abort conditions as the shared pass, because they are the same two calls with the `only:`
    /// filter dropped.
    ///
    /// Everything above the work is the gate, and there is no setting for any of it. The pass is
    /// default-on precisely because it can only run where nobody pays for it: charging, on a
    /// network nobody is billed by the megabyte for, and with the library's own imports already
    /// settled. A toggle would exist to protect the user from a cost the gate has already ruled
    /// out. The guards run with no `await` between them and `isImporting = true`, so a background
    /// wake and a foreground kick cannot both get through.
    private func runLibraryDeepPass() async {
        guard Self.cloudImportEnabled, StashSession.shared.isSignedIn else { return }
        guard !isImporting, !deepPassBlocked else { return }
        // A share is what the user is standing there waiting for, and an import still landing is
        // a fast pass with nothing to deepen yet. The library has been waiting for months; it
        // can wait for those.
        guard pendingShares.isEmpty, shareImports.isEmpty, !cloudState.isActive else { return }
        guard Self.isCharging, Self.isOnUnmeteredPath else { return }
        guard let runner = makeRunner() else { return }
        let read = Self.makeDeepPassReader()

        isImporting = true
        // Deliberately not disabling the idle timer, unlike every other drain here: nobody asked
        // for this pass, so it must not be the reason a charging phone never sleeps. Locking the
        // screen ends it part-way, which is exactly what the background task is for.
        defer {
            isImporting = false
            progress = nil
            deepPassReading = nil
        }
        deepPassReading = "Transcripts"
        let transcripts = await runner.backfillTranscripts { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }
        deepPassReading = "Screen text"
        let visual = await runner.backfillVisualText(deepPass: read) { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }

        // Budget spent, the box's daily deep-pass cap reached, or the network gone — all three
        // mean "not now", and all three are already understood by the flag the shared pass sets.
        // No `lastError`: an unasked-for pass must not put a sentence in front of anyone.
        guard transcripts.quotaExhausted == nil, visual.quotaExhausted == nil,
              !transcripts.stoppedEarly, !visual.stoppedEarly else {
            deepPassBlocked = true
            return
        }
        if transcripts.filled + visual.filled > 0 {
            lastSummary = "Read \(transcripts.filled) transcripts and \(visual.filled) screens "
                + "from the library"
        }
    }

    /// Both halves of the gate's hardware question have to be watched before they can be asked:
    /// `batteryState` is `.unknown` until monitoring is on, and a monitor's `currentPath` is
    /// meaningless for the first instant of its life. Started at launch so the first foreground
    /// already has an answer.
    private static let pathMonitor = NWPathMonitor()

    private static func startPowerAndPathWatch() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        pathMonitor.start(queue: DispatchQueue(label: "dev.dmitryschab.Stash.path"))
    }

    private static var isCharging: Bool {
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }

    /// Wi-Fi or wired, never a cellular or personal-hotspot path: the deep pass downloads every
    /// video in the library, and `isExpensive` is iOS's own word for "the user pays for this".
    private static var isOnUnmeteredPath: Bool {
        let path = pathMonitor.currentPath
        return path.status == .satisfied && !path.isExpensive
    }

    // MARK: - Re-analysis

    /// Re-buckets the existing library against the current category taxonomy: re-runs the
    /// analyzer on every stored video using text already fetched (no re-enrich/transcribe).
    /// User-initiated one-shot; works in cloud or local mode since it only talks to the box.
    func reanalyzeLibrary() {
        guard !isImporting, let runner = makeRunner() else { return }
        lastError = nil
        processingTask = Task { [weak self] in
            await self?.drainReanalyze(runner: runner)
        }
    }

    private func drainReanalyze(runner: PipelineRunner) async {
        isImporting = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isImporting = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        await runner.reanalyzeAll { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }
        lastSummary = "Re-analyzed the library"
    }

    /// Fetches transcripts for saves that never got one and re-analyzes them with it. Paced and
    /// resumable — the cloud Whisper quota is hourly, so this is expected to take several runs.
    func backfillTranscripts() {
        guard !isImporting, let runner = makeRunner() else { return }
        lastError = nil
        processingTask = Task { [weak self] in
            await self?.drainBackfill(runner: runner)
        }
    }

    private func drainBackfill(runner: PipelineRunner) async {
        isImporting = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isImporting = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let result = await runner.backfillTranscripts { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }
        if let quota = result.quotaExhausted {
            lastError = "Import budget used up — filled \(result.filled), \(result.remaining) "
                + "still to go. \(quota.monthLimit) more on "
                + quota.monthResetDate.formatted(date: .abbreviated, time: .omitted) + "."
        } else if result.stoppedEarly {
            lastError = "Transcription is being throttled — filled \(result.filled), "
                + "\(result.remaining) still to go. Try again in an hour."
        } else {
            lastSummary = "Filled \(result.filled) transcripts · \(result.remaining) left"
        }
    }

    /// Reads the words burned into each video's frames and re-analyzes with them. Vision OCR is
    /// free and unmetered, so this is the cheap signal — the cost is downloading the videos.
    func backfillVisualText() {
        guard !isImporting, let runner = makeRunner() else { return }
        lastError = nil
        let read = Self.makeDeepPassReader()
        processingTask = Task { [weak self] in
            await self?.drainVisualBackfill(runner: runner, read: read)
        }
    }

    /// Downloads the video through the box (TikTok blocks in-app fetches), samples frames, runs
    /// on-device Vision OCR, and asks ShazamKit what is playing. More keyframes than the pipeline
    /// default: on-screen text changes fast, and frames are cheap once the video is already
    /// downloaded — and so is the audio, which is why both reads happen here rather than in two
    /// passes that would pay for the download twice.
    private static func makeDeepPassReader() -> @Sendable (String, URL) async throws -> DeepPass {
        let config = currentConfig()
        let baseURL = config.baseURL
        let auth = config.auth   // closures, not a token: refreshes mid-backfill reach this
        return { videoID, _ in
            let file: URL
            do {
                file = try await BoxVideoDownload.temporaryFile(
                    videoID: videoID, baseURL: baseURL, auth: auth)
            } catch is BoxVideoDownload.NoVideoTrack {
                // A photo post: there are no frames to sample and there never will be. An empty
                // pass is the same answer as "this video carries nothing to read", which marks
                // the stage done — so a library full of photo posts cannot trip the abort
                // threshold and stop the pass before it reaches the real videos.
                return DeepPass()
            }
            defer { try? FileManager.default.removeItem(at: file) }
            let frames = try await MediaFetcher(keyframeCount: 12).keyframes(fromLocalFile: file)
            defer { frames.forEach { try? FileManager.default.removeItem(at: $0) } }
            let text = try await FrameReader().recognizeText(in: frames)
            // Inside the same statement group as the download, so the mp4 is still on disk here
            // and is still deleted on the way out however this returns.
            let match = await ShazamResolver().match(fileURL: file)
            return DeepPass(visualText: text.isEmpty ? nil : text, audioMatch: match)
        }
    }

    private func drainVisualBackfill(
        runner: PipelineRunner,
        read: @escaping @Sendable (String, URL) async throws -> DeepPass
    ) async {
        isImporting = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isImporting = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let result = await runner.backfillVisualText(deepPass: read) { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }
        if let quota = result.quotaExhausted {
            lastError = "Import budget used up — read \(result.filled), \(result.remaining) "
                + "still to go. \(quota.monthLimit) more on "
                + quota.monthResetDate.formatted(date: .abbreviated, time: .omitted) + "."
        } else if result.stoppedEarly {
            lastError = "Stopped after repeated download failures — read \(result.filled), "
                + "\(result.remaining) still to go. Check your connection and try again."
        } else {
            lastSummary = "Read on-screen text for \(result.filled) · \(result.remaining) left"
        }
    }

    // MARK: - Lifecycle (called from the App's scenePhase watcher)

    func appBecameActive() {
        endExtraTime()
        cancelPendingFirstSlicePing()
        // Cover art comes from TikTok's public oEmbed endpoint, not the box, so it is worth
        // retrying on a foreground the sign-in gate is still covering.
        refreshThumbnails()
        // Fires from the Scene-level watcher, which runs while the sign-in gate is still up.
        guard StashSession.shared.isSignedIn else { return }
        // /v1/me first: on a cold launch it is what says a TikTok is connected at all.
        Task { [weak self] in
            await StashSession.shared.refreshQuota()
            await self?.syncTikTok()
        }
        deepPassBlocked = false   // a new foreground is exactly when retrying is worth it
        backfillEmbeddings()
        backfillOffers()
        if Self.cloudImportEnabled {
            drainSharedInbox()
            syncCloudImportIfNeeded()
            startLibraryDeepPassIfReady()
            retryArchived(manual: false)
        } else {
            resumePendingIfNeeded()
        }
    }

    func appEnteredBackground() {
        if Self.cloudImportEnabled {
            cloudSyncTask?.cancel()
            cloudSyncTask = nil
            // The library pass wants a charger and Wi-Fi, which is a description of the night —
            // so the window it is most likely to run in is one iOS grants after this point.
            scheduleDeepPassProcessing()
            if cloudState.isActive || StashSession.shared.tiktok != nil { scheduleCloudRefresh() }
            scheduleFirstSlicePing()
            return
        }
        guard isImporting else { return }
        // Finish the current stretch on borrowed time (~30 s – a few min)…
        extraTime = UIApplication.shared.beginBackgroundTask(withName: "stash-import") { [weak self] in
            Task { @MainActor in
                self?.processingTask?.cancel()
                self?.endExtraTime()
            }
        }
        // …and ask for a processing window later for the rest.
        scheduleBackgroundProcessing()
    }

    private func endExtraTime() {
        if extraTime != .invalid {
            UIApplication.shared.endBackgroundTask(extraTime)
            extraTime = .invalid
        }
    }

    // MARK: - BGProcessingTask

    /// Registered once at launch (must run before the app finishes launching).
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in Self.shared.handleBackgroundTask(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: deepPassTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in Self.shared.handleDeepPassBackgroundTask(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in Self.shared.handleCloudRefreshTask(task) }
        }
    }

    // MARK: - Cloud refresh while closed

    // ponytail: BGAppRefresh is opportunistic — iOS runs it minutes to hours after the request,
    // so the ping lands late rather than never. Upgrade path: an APNs push from the box.
    func scheduleCloudRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleCloudRefreshTask(_ task: BGAppRefreshTask) {
        let work = Task { [weak self] in
            await StashSession.shared.restore()
            guard let self, StashSession.shared.isSignedIn else {
                task.setTaskCompleted(success: true)
                return
            }
            if cloudState.isActive {
                await syncCloudImport()
                if !cloudState.isActive, let status = cloudState.status { Self.notifyLibraryReady(status) }
            }
            // A favourite bookmarked in TikTok can land while Stash stays closed; a ready archive
            // starts an import, which the next window then polls like any other.
            await syncTikTok()
            if cloudState.isActive || StashSession.shared.tiktok != nil {
                scheduleCloudRefresh()   // still cooking, or a TikTok to ask again — next window
            }
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in Self.shared.scheduleCloudRefresh() }
            task.setTaskCompleted(success: false)
        }
    }

    /// One local notification per finished import. Unauthorized centers drop it silently,
    /// which is the right amount of noise for someone who said no.
    static func notifyLibraryReady(_ status: CloudImportStatus) {
        let content = UNMutableNotificationContent()
        content.title = "Your library is ready"
        let sorted = status.fastPass.done - status.unavailable
        content.body = "\(max(sorted, 0)) videos sorted onto your shelves. Open Stash to browse."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "library-ready-\(status.importID)", content: content, trigger: nil))
    }

    // MARK: - First-slice ping

    // ponytail: a timed guess, not a report — the box cannot reach a backgrounded phone and
    // BGAppRefresh runs 15+ minutes late. Upgrade path: an APNs push from the box.
    private static let firstSlicePingKey = "firstSlicePing"

    /// Seconds until the newest slice is likely sorted, or nil when there is nothing to wait
    /// for: a library that fits in one slice, or a first slice already done.
    static func firstSliceDelay(done: Int, total: Int, rate: Double?) -> TimeInterval? {
        let slice = CloudImportLimits.firstSlice
        guard total > slice, done < slice else { return nil }
        let perSecond = rate.flatMap { $0 > 0 ? $0 : nil } ?? 0.5   // 4 workers ÷ ~8 s a video
        return min(max(Double(slice - done) / perSecond, 60), 900)
    }

    /// The stored ping, "<importID>|<fire time in epoch seconds>".
    static func parsePing(_ stored: String?) -> (importID: String, fireAt: Date)? {
        guard let parts = stored?.split(separator: "|"), parts.count == 2,
              let epoch = TimeInterval(parts[1]) else { return nil }
        return (String(parts[0]), Date(timeIntervalSince1970: epoch))
    }

    /// One ping per import: only a ping for this same import that has already gone off stops
    /// another. A previous import's ping, or one still pending, does not.
    static func shouldSchedulePing(stored: String?, importID: String, now: Date) -> Bool {
        guard let ping = parsePing(stored), ping.importID == importID else { return true }
        return ping.fireAt > now
    }

    #if DEBUG
    static func firstSliceSelfTest() -> Bool {
        let now = Date()
        let past = "imp-1|\(now.addingTimeInterval(-5).timeIntervalSince1970)"
        let future = "imp-1|\(now.addingTimeInterval(120).timeIntervalSince1970)"
        return firstSliceDelay(done: 20, total: 941, rate: 0.5) == 160
            && firstSliceDelay(done: 20, total: 941, rate: nil) == 160     // no measurement yet
            && firstSliceDelay(done: 20, total: 941, rate: 0) == 160       // no progress yet
            && firstSliceDelay(done: 99, total: 941, rate: 0.5) == 60      // clamped up
            && firstSliceDelay(done: 0, total: 941, rate: 0.01) == 900     // clamped down
            && firstSliceDelay(done: 100, total: 941, rate: 0.5) == nil    // already sorted
            && firstSliceDelay(done: 0, total: 100, rate: 0.5) == nil      // one slice is the library
            && parsePing(past)?.importID == "imp-1"
            && parsePing("imp-1") == nil && parsePing(nil) == nil
            && !shouldSchedulePing(stored: past, importID: "imp-1", now: now)   // it went off
            && shouldSchedulePing(stored: future, importID: "imp-1", now: now)  // still pending: reschedule
            && shouldSchedulePing(stored: past, importID: "imp-2", now: now)    // a new import
            && shouldSchedulePing(stored: nil, importID: "imp-1", now: now)
    }
    #endif

    private func scheduleFirstSlicePing() {
        guard cloudState.isActive, let status = cloudState.status else { return }
        let now = Date()
        let rate = firstPollSample.flatMap { sample -> Double? in
            let elapsed = now.timeIntervalSince(sample.at)
            guard sample.importID == status.importID, elapsed > 0 else { return nil }
            return Double(status.fastPass.done - sample.done) / elapsed
        }
        let defaults = UserDefaults.standard
        guard let delay = Self.firstSliceDelay(done: status.fastPass.done, total: status.fastPass.total, rate: rate),
              Self.shouldSchedulePing(stored: defaults.string(forKey: Self.firstSlicePingKey),
                                      importID: status.importID, now: now) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Your newest saves are sorted"
        content.body = "Open Stash to browse — the rest keeps sorting."
        content.sound = .default
        // Same identifier on every background: a second schedule replaces the first.
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "first-slice-\(status.importID)", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)))
        defaults.set("\(status.importID)|\(now.addingTimeInterval(delay).timeIntervalSince1970)",
                     forKey: Self.firstSlicePingKey)
    }

    /// Back in the app before the ping went off: the card says it now, so the ping would be noise.
    private func cancelPendingFirstSlicePing() {
        let defaults = UserDefaults.standard
        guard let ping = Self.parsePing(defaults.string(forKey: Self.firstSlicePingKey)),
              ping.fireAt > Date() else { return }
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["first-slice-\(ping.importID)"])
        defaults.removeObject(forKey: Self.firstSlicePingKey)
    }

    /// Pull-to-refresh: one full poll now, ahead of the 8-second repoll. Waits out a poll that
    /// is already in flight so the spinner means "checked", not "asked".
    func refresh() async {
        guard StashSession.shared.isSignedIn else { return }
        await StashSession.shared.refreshQuota()
        refreshThumbnails()
        guard Self.cloudImportEnabled else { resumePendingIfNeeded(); return }
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        while cloudSyncing { try? await Task.sleep(nanoseconds: 200_000_000) }
        drainSharedInbox()
        await syncCloudImport()
    }

    private func handleBackgroundTask(_ task: BGProcessingTask) {
        guard let runner = makeRunner() else {
            task.setTaskCompleted(success: false)
            return
        }
        let work = Task { [weak self] in
            // A background launch never rendered RootView, so the Keychain may still be unread
            // — restore before the guard, or every wake after a cold start would decline.
            await StashSession.shared.restore()
            guard StashSession.shared.isSignedIn else {
                task.setTaskCompleted(success: false)   // nothing we are allowed to do
                return
            }
            await self?.drainQueue(runner: runner)
            let remaining = (try? await runner.pendingCount()) ?? 0
            if remaining > 0 { self?.scheduleBackgroundProcessing() }  // next window
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()  // processAll stops between videos; progress is persisted
            Task { @MainActor in Self.shared.scheduleBackgroundProcessing() }
            task.setTaskCompleted(success: true)
        }
    }

    func scheduleBackgroundProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)  // duplicate submits just replace
    }

    /// The deep pass's own window, asked for on iOS's terms rather than only on ours: external
    /// power is half the gate in `runLibraryDeepPass`, so saying it here lets the scheduler pick
    /// a moment that already satisfies it instead of waking us to find out it does not.
    func scheduleDeepPassProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.deepPassTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleDeepPassBackgroundTask(_ task: BGProcessingTask) {
        let work = Task { [weak self] in
            // Same cold-start problem as the import task: a background launch never rendered
            // RootView, so the session is still sitting unread in the Keychain.
            await StashSession.shared.restore()
            await self?.runLibraryDeepPass()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            // A direct call, so cancellation reaches the backfills — both stop between videos,
            // and every stage they finished is already stored.
            work.cancel()
            Task { @MainActor in Self.shared.scheduleDeepPassProcessing() }  // next window
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - Cloud import synchronization

    func syncCloudImportIfNeeded() {
        guard StashSession.shared.isSignedIn else { return }
        guard Self.cloudImportEnabled, !cloudSyncing else { return }
        guard cloudState.importID != nil || !shareImports.isEmpty else { return }
        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self] in
            await self?.syncCloudImport()
        }
    }

    /// Drops the record of the last cloud import — both the persisted copy and the in-memory
    /// one, which would otherwise be written straight back. Used by account deletion.
    func forgetCloudState() {
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        cloudState = CloudImportSyncState()
        cloudStatus = nil
        shareImports = []
        pendingShares = []
        // The pill's route flag is part of that record: left raised, the next Library render
        // pushes Import at an account that no longer has an import to look at.
        importRouteRequested = false
        UserDefaults.standard.removeObject(forKey: Self.cloudStateKey)
        UserDefaults.standard.removeObject(forKey: Self.shareImportsKey)
        UserDefaults.standard.removeObject(forKey: Self.archiveRetriesKey)
        UserDefaults.standard.removeObject(forKey: Self.archiveRetryAtKey)
    }

    // MARK: - TikTok sync

    /// Asks the box for a connected TikTok's favourites — part two of the integration
    /// (docs/superpowers/specs/2026-10-07-tiktok-portability-p2-design.md). The box asks TikTok
    /// for the data archive at most once a day and answers every other call from its own row,
    /// so this is cheap enough for every foreground and every background refresh.
    ///
    /// Only asks while the import slot is free: a finished archive is handed over once, and it
    /// goes through the same submit as a picked export. While an import runs, TikTok's answer
    /// waits on the box instead. Errors are only logged — the next foreground asks again.
    func syncTikTok() async {
        let session = StashSession.shared
        guard !tiktokSyncing, session.isSignedIn, session.tiktok != nil, Self.cloudImportEnabled,
              !isImporting, !cloudState.isActive else { return }
        tiktokSyncing = true
        defer { tiktokSyncing = false }
        do {
            let result = try await TikTokConnectClient(config: Self.currentConfig()).sync()
            tiktokSyncWaiting = result == .pending || result == .requested
            switch result {
            case .notConnected:
                session.tiktok = nil   // revoked in TikTok, or disconnected from another phone
            case .ready(let favorites):
                await session.refreshQuota()   // the new lastSyncAt for Settings, and the budget
                await importSynced(favorites)
            case .notEnabled, .pending, .requested, .idle:
                break
            }
        } catch {
            NSLog("PipelineCenter: TikTok sync failed: %@", String(describing: error))
        }
    }

    /// A finished archive's favourites, minus every one the library already has
    /// (`TikTokSyncResult.toSubmit`), through the import a picked export takes. Nothing new
    /// means no import at all. An import started while the box was answering wins the slot;
    /// these favourites are not stored, so the next archive brings them again.
    private func importSynced(_ favorites: [Bookmark]) async {
        guard !isImporting, !cloudState.isActive, let container, let runner = makeRunner(),
              let client = Self.makeCloudClient() else {
            NSLog("PipelineCenter: import slot busy, %@ synced favourites left for the next archive",
                  "\(favorites.count)")
            return
        }
        let libraryIDs = Set(((try? ModelContext(container).fetch(FetchDescriptor<Video>())) ?? []).map(\.videoID))
        let budget = StashSession.shared.quota?.remaining ?? CloudImportLimits.maxVideosPerImport
        let picks = TikTokSyncResult.toSubmit(favorites, libraryIDs: libraryIDs, budget: budget)
        guard !picks.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }
        _ = await submitCloudImport(picks, runner: runner, client: client)
    }

    // MARK: - Archive retries

    private static let archiveRetriesKey = "archive.autoRetries"
    private static let archiveRetryAtKey = "archive.lastAutoRetryAt"
    private static let maxAutoRetries = 3
    private static let autoRetrySpacing: TimeInterval = 6 * 3600

    /// Re-submits archived saves as a cloud import. The box re-runs a save that already failed
    /// without charging for it (cloud_import_store.MAX_FREE_RETRIES), and the upserter lets the
    /// success replace the failure.
    ///
    /// Automatic runs (every foreground) take failed saves only — a deleted TikTok stays
    /// deleted — at most every 6 hours and 3 times per save. Manual runs take the whole archive.
    /// ponytail: attempt counts live in UserDefaults, not on `Video`, so a counter costs no
    /// SwiftData migration.
    func retryArchived(manual: Bool) {
        guard StashSession.shared.isSignedIn, !StashSession.shared.isDemoAccount, Self.cloudImportEnabled,
              !isImporting, !cloudState.isActive, let container else { return }
        let defaults = UserDefaults.standard
        if !manual, let last = defaults.object(forKey: Self.archiveRetryAtKey) as? Date,
           Date.now.timeIntervalSince(last) < Self.autoRetrySpacing { return }
        var counts = defaults.dictionary(forKey: Self.archiveRetriesKey) as? [String: Int] ?? [:]
        let archived = ((try? ModelContext(container).fetch(FetchDescriptor<Video>(
            predicate: #Predicate { $0.unavailable || $0.categoryRaw == "" }))) ?? []).filter(\.isArchived)
        let targets = manual ? archived : archived.filter {
            !$0.unavailable && counts[$0.videoID, default: 0] < Self.maxAutoRetries
        }
        guard !targets.isEmpty else { return }
        if !manual {
            targets.forEach { counts[$0.videoID, default: 0] += 1 }
            defaults.set(counts, forKey: Self.archiveRetriesKey)
            defaults.set(Date.now, forKey: Self.archiveRetryAtKey)
        }
        let bookmarks = targets.prefix(CloudImportLimits.maxVideosPerImport)
            .map { Bookmark(id: $0.videoID, url: $0.url, date: $0.bookmarkedAt) }
        isImporting = true
        Task { [weak self] in await self?.submitRetry(bookmarks) }
    }

    /// Takes the library-import slot, so the existing poll applies the results and Import
    /// shows the progress. Only called while that slot is idle.
    private func submitRetry(_ bookmarks: [Bookmark]) async {
        defer { isImporting = false }
        guard let client = Self.makeCloudClient() else { return }
        // A poll of the previous import still in flight would write its cursor into the new state.
        cloudSyncTask?.cancel()
        cloudSyncTask = nil
        while cloudSyncing { try? await Task.sleep(nanoseconds: 200_000_000) }
        do {
            let clientImportID = UUID()
            let submission = try await client.submit(bookmarks: bookmarks, clientImportID: clientImportID)
            cloudState = CloudImportSyncState(importID: submission.importID, clientImportID: clientImportID)
            persistCloudState()
            lastSummary = "Retrying \(submission.accepted) archived saves"
            await syncCloudImport()
        } catch {
            lastError = "Could not retry archived saves: \(error.localizedDescription)"
        }
    }

    private func persistCloudState() {
        if let data = try? JSONEncoder().encode(cloudState) {
            UserDefaults.standard.set(data, forKey: Self.cloudStateKey)
        }
        cloudStatus = cloudState.status
    }

    /// One poll of everything outstanding. The library import and the share imports are polled
    /// separately because they are independent: a fresh account can have a shared TikTok in
    /// flight with no library import at all, and a share made mid-import must not disturb it.
    private func syncCloudImport() async {
        guard !cloudSyncing else { return }
        cloudSyncing = true
        defer { cloudSyncing = false }

        // Not `&&`: short-circuiting would skip the share poll whenever the library one failed.
        let libraryOK = await syncLibraryImport()
        let sharesOK = await syncShareImports()
        if libraryOK, sharesOK {
            scheduleCloudRepoll()
        } else {
            cloudSyncTask = nil
        }
    }

    /// Polls the one-off imports the share extension produced, and starts the deep pass for any
    /// that have finished. Each poll re-reads the whole result set rather than carrying a cursor:
    /// a share is a handful of videos, and `CloudImportResultUpserter` ignores anything it has
    /// already applied. Returns false when re-polling cannot help.
    private func syncShareImports() async -> Bool {
        guard !shareImports.isEmpty else { return true }
        if let client = Self.makeCloudClient() {
            for share in shareImports {
                guard let importID = share.importID else { continue }
                do {
                    let status = try await client.status(importID: importID)
                    let results = try await client.allResults(importID: importID)
                    if let container {
                        let applied = try await Self.apply(results, to: container)
                        if applied > 0 {
                            refreshThumbnails()
                            backfillEmbeddings()   // a classified save is one there is text to embed
                            backfillOffers()
                        }
                    }
                    guard status.state == .completed || status.state == .cancelled else { continue }
                    for index in shareImports.indices where shareImports[index].id == share.id {
                        shareImports[index].importID = nil
                    }
                    persistShareImports()
                    // The fast pass classified these saves — the real rows carry the story
                    // from here, so their placeholders leave.
                    pendingShares.removeAll { !Set($0.videoIDs).isDisjoint(with: share.videoIDs) }
                } catch is CancellationError {
                    return true
                } catch let error as StashError {
                    // Session gone or budget spent: neither is fixed by polling again.
                    failPendingShares(message: error.localizedDescription, holdSeconds: 8)
                    lastError = error.localizedDescription
                    return false
                } catch {
                    lastError = "Could not sync the shared TikTok: \(error.localizedDescription)"
                }
            }
        }
        startDeepPassIfReady()
        return true
    }

    /// Returns false when the failure is one that re-polling cannot fix.
    private func syncLibraryImport() async -> Bool {
        guard let importID = cloudState.importID, let client = Self.makeCloudClient() else { return true }

        do {
            let status = try await client.status(importID: importID)
            cloudState.apply(status: status)
            persistCloudState()
            if firstPollSample?.importID != status.importID {
                firstPollSample = (status.importID, Date(), status.fastPass.done)
            }
            if let guesses = status.map?.guesses, !guesses.isEmpty, let container,
               try await Self.applyGuesses(guesses, to: container) > 0 {
                refreshTallies()
            }

            var cursor = cloudState.nextResultsCursor
            var seenCursors = Set<String>()
            while true {
                let page = try await client.results(importID: importID, cursor: cursor)
                if let container {
                    let applied = try await Self.apply(page.results, to: container)
                    if applied > 0 {
                        refreshTallies()
                        lastSummary = "Synced \(applied) cloud results"
                        refreshThumbnails()
                        backfillEmbeddings()
                        backfillOffers()
                    }
                }
                guard let nextCursor = page.nextCursor else {
                    cloudState.nextResultsCursor = nil
                    persistCloudState()
                    break
                }
                guard seenCursors.insert(nextCursor).inserted else {
                    throw CloudImportError.malformedPayload("result cursor repeated")
                }
                cursor = nextCursor
                cloudState.nextResultsCursor = nextCursor
                persistCloudState()
            }
            // No completion line written here: the Import hero derives its own from `cloudStatus`
            // and the "library is ready" notification says it in words a person uses. What stood
            // here counted "unavailable" and "partial failures" at whoever happened to be looking.
        } catch is CancellationError {
            return true
        } catch let error as StashError {
            // Polling itself costs nothing, but the box can still refuse the session or report
            // a spent budget on the way through. Both already read as sentences, and neither is
            // fixed by re-polling — so no prefix and no "will retry automatically".
            lastError = error.localizedDescription
            return false
        } catch {
            var message = "Could not check on your import: \(error.localizedDescription)"
            if let cloudError = error as? CloudImportError, cloudError.isRetryable { message += " Will retry automatically." }
            lastError = message
        }
        return true
    }

    /// The upsert fetches the whole library to match ids, then writes and saves. On the main
    /// actor that was a stall every eight-second poll of a running import; its own context on
    /// a detached task is the pattern every other drain here already follows.
    private static func apply(_ results: [CloudImportResult], to container: ModelContainer) async throws -> Int {
        try await Task.detached(priority: .utility) {
            try CloudImportResultUpserter.apply(results, to: ModelContext(container))
        }.value
    }

    private func scheduleCloudRepoll() {
        guard cloudState.isActive || !shareImports.isEmpty else {
            cloudSyncTask = nil
            return
        }
        cloudSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.syncCloudImport()
        }
    }

    // MARK: - Box reachability probe

    func pingBox() async {
        boxStatus = .checking
        let analyzer = AnalyzerClient(config: Self.currentConfig())
        do {
            _ = try await analyzer.analyze(meta: VideoMeta(caption: "ping"), transcript: nil, ocrText: nil)
            boxStatus = .online
        } catch StashError.unauthenticated {
            // Not a reachability problem: the session is gone and the gate is already taking
            // over (StashSession signs out when the refresh is refused).
            boxStatus = .unknown
        } catch StashError.quotaExhausted {
            boxStatus = .online  // it answered — the budget is what ran out
        } catch let error as BoxError {
            switch error {
            case .unreachable:
                boxStatus = .offline
            case .badResponse(let status) where status == 403:
                // Reaching the box and being refused is NOT online — surface it.
                boxStatus = .offline
            default:
                boxStatus = .online  // it answered; model hiccups still count as reachable
            }
        } catch {
            boxStatus = .offline
        }
    }
}

// MARK: - Embedding backfill

/// Fills `Video.embedding` for saves that have none, in serial batches of 32 — the box's own cap.
///
/// Its own actor rather than a `PipelineRunner` stage because it shares none of that queue's
/// problems: nothing here is downloaded, metered or ordered, and the text it embeds is text the
/// analysis already produced. Off the main actor for the same reason every other drain is — the
/// fetch is the whole library.
///
/// The first failed batch ends the run rather than counting failures like the transcript drain:
/// the only ways this call fails are "offline", "box down" and "signed out", and none of the
/// three gets better on the next batch. Everything already written is saved, and the next
/// foreground resumes from there.
actor EmbeddingBackfill {
    private let container: ModelContainer
    private let embedder: BoxEmbeddingClient

    init(container: ModelContainer, embedder: BoxEmbeddingClient) {
        self.container = container
        self.embedder = embedder
    }

    func run() async {
        let context = ModelContext(container)
        let all = (try? context.fetch(FetchDescriptor<Video>(
            sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]))) ?? []
        // Newest first, and never a save with nothing written about it yet: an unanalyzed row
        // would cost a round trip to embed the empty string.
        let pending = all.filter {
            $0.embeddingRevision < BoxEmbeddingClient.revision && !$0.embeddingText.isEmpty
        }

        let batchSize = BoxEmbeddingClient.maxTextsPerRequest
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            if Task.isCancelled { return }
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            guard let vectors = try? await embedder.embed(batch.map(\.embeddingText)) else { return }
            for (video, vector) in zip(batch, vectors) {
                video.embedding = EmbeddingVector.pack(vector)
                video.embeddingRevision = BoxEmbeddingClient.revision
            }
            try? context.save()
        }
    }
}

// MARK: - Transient video download

/// Fetches a video through the box (`GET {base}/tiktok/download/{id}`, yt-dlp server-side —
/// pure in-app downloading is impossible against current TikTok controls: pages serve a blank
/// playAddr without the JS handshake and the CDN 403s cookie-replayed stream URLs) into a
/// temporary file the caller deletes immediately.
///
/// Deliberately temporary-only. Persistent user-facing copies were removed (App Store
/// guideline 5.2.3); the sole caller is `makeDeepPassReader`, which samples frames for on-device
/// OCR, matches the audio against the Shazam catalogue, and unlinks the file in the same
/// statement group. Costs no quota — the video was charged for at import, and re-reading a save
/// must not cost as much as saving it — but the box caps these calls per account per day, and
/// over that cap this returns the 429 every other download failure already looks like.
enum BoxVideoDownload {
    /// The post is a TikTok photo post — a still and a backing track, no video track to sample.
    /// Permanent, so callers skip the read rather than retrying it.
    struct NoVideoTrack: Error {}

    static func temporaryFile(videoID: String, baseURL: URL, auth: StashAuthProvider) async throws -> URL {
        var request = URLRequest(url: baseURL.appendingPathComponent("tiktok/download/\(videoID)"))
        request.timeoutInterval = 120  // yt-dlp on the box takes 5–20 s per video

        let (data, response) = try await StashHTTP.send(request, on: .shared, auth: auth)
        guard response.statusCode != 415 else { throw NoVideoTrack() }
        // Valid mp4s carry "ftyp" at byte 4; error bodies are small HTML/text.
        guard response.statusCode == 200,
              data.count > 50_000,
              data.subdata(in: 4..<8) == Data("ftyp".utf8) else {
            throw URLError(.badServerResponse)
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-ocr-\(videoID).mp4")
        try data.write(to: file, options: .atomic)
        return file
    }
}
