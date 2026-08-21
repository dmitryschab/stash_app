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
import SwiftData
import SwiftUI
import TikTokBrainKit
import UIKit

@MainActor
@Observable
final class PipelineCenter {
    static let shared = PipelineCenter()
    static let bgTaskID = "dev.dmitryschab.Stash.process"

    var progress: (done: Int, total: Int)?
    var isImporting = false
    var boxStatus: BoxStatus = .unknown
    var lastError: String?
    var lastSummary: String?
    var cloudStatus: CloudImportStatus?
    var cloudSyncing = false

    var cloudImportEnabled: Bool { Self.cloudImportEnabled }

    private var container: ModelContainer?
    private var processingTask: Task<Void, Never>?
    private var cloudSyncTask: Task<Void, Never>?
    private var extraTime: UIBackgroundTaskIdentifier = .invalid
    private var cloudState = CloudImportSyncState()
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
        Self.discardLegacyState()
        refreshThumbnails()
    }

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

    private func runLocalImport(url: URL) async {
        guard !isImporting, let runner = makeRunner() else { return }
        lastError = nil

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let bookmarks: [Bookmark]
        do {
            let parser = ExportParser()
            if url.hasDirectoryPath {
                bookmarks = try parser.parse(zipAt: url)
            } else {
                bookmarks = try parser.parse(jsonData: Data(contentsOf: url))
            }
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
        guard !isImporting, let runner = makeRunner(), let client = Self.makeCloudClient() else {
            lastError = "Cloud import isn't configured — check the base URL in Settings."
            return
        }
        lastError = nil

        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let bookmarks: [Bookmark]
        do {
            let parser = ExportParser()
            if url.hasDirectoryPath {
                bookmarks = try parser.parse(zipAt: url)
            } else {
                bookmarks = try parser.parse(jsonData: Data(contentsOf: url))
            }
        } catch {
            lastError = "Could not read the export: \(error.localizedDescription)"
            return
        }

        guard !bookmarks.isEmpty else {
            lastError = "The export contains no bookmarked videos."
            return
        }
        guard bookmarks.count <= CloudImportLimits.maxVideosPerImport else {
            lastError = CloudImportError.tooManyVideos(bookmarks.count).localizedDescription
            return
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
            return
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
            isImporting = true
            defer { isImporting = false }
            let submission = try await client.submit(bookmarks: submitting, clientImportID: clientImportID)
            cloudState.importID = submission.importID
            persistCloudState()
            if submitting.count < bookmarks.count, let quota {
                let refills = quota.monthResetDate.formatted(date: .abbreviated, time: .omitted)
                lastSummary = "Submitted the newest \(submission.accepted) of \(bookmarks.count) "
                    + "· that is the whole budget · \(quota.monthLimit) more on \(refills)"
            } else {
                lastSummary = "Submitted \(submission.accepted) videos · \(newCount) new"
            }
            await syncCloudImport()
        } catch let error as StashError {
            // Quota and session failures already read as sentences; prefixing them would not help.
            lastError = error.localizedDescription
        } catch {
            var message = "Could not submit the cloud import: \(error.localizedDescription)"
            if let cloudError = error as? CloudImportError, cloudError.isRetryable { message += " Will retry automatically." }
            lastError = message
        }
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
            lastError = "Cloud import isn't configured — check the base URL in Settings."
            return
        }
        isImporting = true
        defer { isImporting = false }
        lastError = nil

        let batch = await SharedLinkResolver.resolve(links) { try await TikTokLink.resolve($0) }
        batch.requeue.forEach { _ = try? inbox.write($0) }
        lastError = batch.rejectionMessage
        let bookmarks = batch.bookmarks
        guard !bookmarks.isEmpty else { return }

        // The counter the box charges against; one unit per video here, as with any import.
        await StashSession.shared.refreshQuota()
        let clientImportID = UUID()
        do {
            _ = try await runner.ingest(bookmarks: bookmarks)
            let submission = try await client.submit(bookmarks: bookmarks, clientImportID: clientImportID)
            shareImports.append(ShareImport(
                id: clientImportID, importID: submission.importID, videoIDs: bookmarks.map(\.id)))
            persistShareImports()
            lastSummary = bookmarks.count == 1
                ? "Saved a shared TikTok — reading it now"
                : "Saved \(bookmarks.count) shared TikToks — reading them now"
            syncCloudImportIfNeeded()
        } catch {
            bookmarks.forEach { _ = try? inbox.write($0.url) }
            if let stashError = error as? StashError {
                lastError = stashError.localizedDescription
            } else {
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
        let extract = Self.makeVisualTextExtractor()
        processingTask = Task { [weak self] in
            await self?.drainDeepPass(runner: runner, shares: ids, videoIDs: videoIDs, extract: extract)
        }
    }

    private func drainDeepPass(
        runner: PipelineRunner,
        shares: Set<UUID>,
        videoIDs: Set<String>,
        extract: @escaping @Sendable (String, URL) async throws -> String?
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
        let visual = await runner.backfillVisualText(only: videoIDs, visualText: extract) { done, total in
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

    private func persistShareImports() {
        if let data = try? JSONEncoder().encode(shareImports) {
            UserDefaults.standard.set(data, forKey: Self.shareImportsKey)
        }
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
        let extract = Self.makeVisualTextExtractor()
        processingTask = Task { [weak self] in
            await self?.drainVisualBackfill(runner: runner, extract: extract)
        }
    }

    /// Downloads the video through the box (TikTok blocks in-app fetches), samples frames, and
    /// runs on-device Vision OCR. More keyframes than the pipeline default: on-screen text
    /// changes fast, and frames are cheap once the video is already downloaded.
    private static func makeVisualTextExtractor() -> @Sendable (String, URL) async throws -> String? {
        let config = currentConfig()
        let baseURL = config.baseURL
        let auth = config.auth   // closures, not a token: refreshes mid-backfill reach this
        return { videoID, _ in
            let file = try await BoxVideoDownload.temporaryFile(
                videoID: videoID, baseURL: baseURL, auth: auth)
            defer { try? FileManager.default.removeItem(at: file) }
            let frames = try await MediaFetcher(keyframeCount: 12).keyframes(fromLocalFile: file)
            defer { frames.forEach { try? FileManager.default.removeItem(at: $0) } }
            let text = try await FrameReader().recognizeText(in: frames)
            return text.isEmpty ? nil : text
        }
    }

    private func drainVisualBackfill(
        runner: PipelineRunner,
        extract: @escaping @Sendable (String, URL) async throws -> String?
    ) async {
        isImporting = true
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isImporting = false
            progress = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let result = await runner.backfillVisualText(visualText: extract) { done, total in
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
        // Cover art comes from TikTok's public oEmbed endpoint, not the box, so it is worth
        // retrying on a foreground the sign-in gate is still covering.
        refreshThumbnails()
        // Fires from the Scene-level watcher, which runs while the sign-in gate is still up.
        guard StashSession.shared.isSignedIn else { return }
        Task { await StashSession.shared.refreshQuota() }
        deepPassBlocked = false   // a new foreground is exactly when retrying is worth it
        if Self.cloudImportEnabled {
            drainSharedInbox()
            syncCloudImportIfNeeded()
        } else {
            resumePendingIfNeeded()
        }
    }

    func appEnteredBackground() {
        if Self.cloudImportEnabled {
            cloudSyncTask?.cancel()
            cloudSyncTask = nil
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
        UserDefaults.standard.removeObject(forKey: Self.cloudStateKey)
        UserDefaults.standard.removeObject(forKey: Self.shareImportsKey)
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
                        let applied = try CloudImportResultUpserter.apply(results, to: ModelContext(container))
                        if applied > 0 { refreshThumbnails() }
                    }
                    guard status.state == .completed || status.state == .cancelled else { continue }
                    for index in shareImports.indices where shareImports[index].id == share.id {
                        shareImports[index].importID = nil
                    }
                    persistShareImports()
                } catch is CancellationError {
                    return true
                } catch let error as StashError {
                    // Session gone or budget spent: neither is fixed by polling again.
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

            var cursor = cloudState.nextResultsCursor
            var seenCursors = Set<String>()
            while true {
                let page = try await client.results(importID: importID, cursor: cursor)
                if let container {
                    let applied = try CloudImportResultUpserter.apply(page.results, to: ModelContext(container))
                    if applied > 0 {
                        lastSummary = "Synced \(applied) cloud results"
                        refreshThumbnails()
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
            if status.state == .completed {
                lastSummary = "Cloud import complete · \(status.unavailable) unavailable · \(status.partialFailures) partial failures"
            }
        } catch is CancellationError {
            return true
        } catch let error as StashError {
            // Polling itself costs nothing, but the box can still refuse the session or report
            // a spent budget on the way through. Both already read as sentences, and neither is
            // fixed by re-polling — so no prefix and no "will retry automatically".
            lastError = error.localizedDescription
            return false
        } catch {
            var message = "Could not sync the cloud import: \(error.localizedDescription)"
            if let cloudError = error as? CloudImportError, cloudError.isRetryable { message += " Will retry automatically." }
            lastError = message
        }
        return true
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

// MARK: - Transient video download

/// Fetches a video through the box (`GET {base}/tiktok/download/{id}`, yt-dlp server-side —
/// pure in-app downloading is impossible against current TikTok controls: pages serve a blank
/// playAddr without the JS handshake and the CDN 403s cookie-replayed stream URLs) into a
/// temporary file the caller deletes immediately.
///
/// Deliberately temporary-only. Persistent user-facing copies were removed (App Store
/// guideline 5.2.3); the sole caller is `makeVisualTextExtractor`, which samples frames for
/// on-device OCR and unlinks the file in the same statement group. Metered like any other
/// quota route: the response carries `X-Stash-Quota` and an empty budget arrives as
/// `StashError.quotaExhausted` from the shared funnel.
enum BoxVideoDownload {
    static func temporaryFile(videoID: String, baseURL: URL, auth: StashAuthProvider) async throws -> URL {
        var request = URLRequest(url: baseURL.appendingPathComponent("tiktok/download/\(videoID)"))
        request.timeoutInterval = 120  // yt-dlp on the box takes 5–20 s per video

        let (data, response) = try await StashHTTP.send(request, on: .shared, auth: auth)
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
