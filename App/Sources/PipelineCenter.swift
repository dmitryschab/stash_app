// PipelineCenter.swift
//
// App-level owner of import processing. Previously the Import screen's private
// controller ran the pipeline, so processing appeared to live and die with that
// screen; now the loop belongs to the app and survives navigation, auto-resumes
// on foreground/launch, asks iOS for extra time when backgrounded mid-import,
// and registers a BGProcessingTask so idle/charging wakes continue the queue.

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

    // MARK: - Wiring

    /// Called once from the App with the shared SwiftData container.
    func configure(container: ModelContainer) {
        self.container = container
        if let data = UserDefaults.standard.data(forKey: Self.cloudStateKey),
           let state = try? JSONDecoder().decode(CloudImportSyncState.self, from: data) {
            cloudState = state
            cloudStatus = state.status
        }
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

    /// Box config from the same defaults the Settings screen writes.
    static func currentConfig() -> BoxConfig {
        let defaults = UserDefaults.standard
        return makeBoxConfig(
            baseURL: defaults.string(forKey: "boxBaseURL") ?? BoxDefaults.baseURL,
            chatModel: defaults.string(forKey: "chatModel") ?? BoxDefaults.chatModel,
            whisperModel: defaults.string(forKey: "whisperModel") ?? BoxDefaults.whisperModel,
            apiKey: defaults.string(forKey: "boxApiKey") ?? BoxDefaults.apiKey)
    }

    private func makeRunner() -> PipelineRunner? {
        guard let container else { return nil }
        return PipelineRunner(deps: Self.makeDeps(config: Self.currentConfig()), container: container)
    }

    /// The cloud-import API lives under the same box base URL and shares the same bearer
    /// token as the rest of `/v1`, so no separate configuration is needed — Settings can
    /// still override the base URL/token for local-box development.
    private static func makeCloudClient() -> CloudImportClient? {
        guard let baseURL = URL(string: UserDefaults.standard.string(forKey: "boxBaseURL") ?? BoxDefaults.baseURL) else { return nil }
        return CloudImportClient(baseURL: baseURL, authorization: {
            let key = UserDefaults.standard.string(forKey: "boxApiKey") ?? BoxDefaults.apiKey
            return key.isEmpty ? BoxDefaults.apiKey : key
        })
    }

    /// Builds the pipeline from the Kit's concrete clients. Shared with the per-video re-run.
    static func makeDeps(config: BoxConfig) -> PipelineDeps {
        PipelineDeps(
            enricher: Enricher(),
            media: MediaFetcher(),
            transcriber: TranscriberClient(config: config),
            analyzer: AnalyzerClient(config: config),
            musicResolver: MusicLinkResolver(),
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
            lastError = "Cloud import isn't configured — check the box URL and API key in Settings."
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

        do {
            let newCount = try await runner.ingest(bookmarks: bookmarks)
            let fingerprint = CloudImportSyncState.fingerprint(of: bookmarks)
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
            let submission = try await client.submit(bookmarks: bookmarks, clientImportID: clientImportID)
            cloudState.importID = submission.importID
            persistCloudState()
            lastSummary = "Submitted \(submission.accepted) videos · \(newCount) new"
            await syncCloudImport()
        } catch {
            var message = "Could not submit the cloud import: \(error.localizedDescription)"
            if let cloudError = error as? CloudImportError, cloudError.isRetryable { message += " Will retry automatically." }
            lastError = message
        }
    }

    /// Continues whatever is pending or parked — no file pick needed. Safe to call
    /// on every foreground/launch; does nothing when idle or already running.
    func resumePendingIfNeeded() {
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
        if result.stoppedEarly {
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
        let baseURL = config.baseURL.absoluteString
        let apiKey = config.apiKey
        return { videoID, _ in
            let file = try await OfflineVideoStore.downloadTemporary(
                videoID: videoID, boxBaseURL: baseURL, apiKey: apiKey)
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
        if result.stoppedEarly {
            lastError = "Stopped after repeated download failures — read \(result.filled), "
                + "\(result.remaining) still to go. Check the box and try again."
        } else {
            lastSummary = "Read on-screen text for \(result.filled) · \(result.remaining) left"
        }
    }

    // MARK: - Lifecycle (called from the App's scenePhase watcher)

    func appBecameActive() {
        endExtraTime()
        if Self.cloudImportEnabled {
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
        guard Self.cloudImportEnabled, cloudState.importID != nil, !cloudSyncing else { return }
        cloudSyncTask?.cancel()
        cloudSyncTask = Task { [weak self] in
            await self?.syncCloudImport()
        }
    }

    private func persistCloudState() {
        if let data = try? JSONEncoder().encode(cloudState) {
            UserDefaults.standard.set(data, forKey: Self.cloudStateKey)
        }
        cloudStatus = cloudState.status
    }

    private func syncCloudImport() async {
        guard !cloudSyncing, let importID = cloudState.importID, let client = Self.makeCloudClient() else { return }
        cloudSyncing = true
        defer { cloudSyncing = false }

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
                    if applied > 0 { lastSummary = "Synced \(applied) cloud results" }
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
            scheduleCloudRepoll()
        } catch is CancellationError {
            return
        } catch {
            var message = "Could not sync the cloud import: \(error.localizedDescription)"
            if let cloudError = error as? CloudImportError, cloudError.isRetryable { message += " Will retry automatically." }
            lastError = message
        }
    }

    private func scheduleCloudRepoll() {
        guard cloudState.isActive else {
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
        } catch let error as BoxError {
            switch error {
            case .unreachable:
                boxStatus = .offline
            case .badResponse(let status) where status == 401 || status == 403:
                // Reaching the box with a bad token is NOT online — surface it.
                boxStatus = .offline
            default:
                boxStatus = .online  // it answered; model hiccups still count as reachable
            }
        } catch {
            boxStatus = .offline
        }
    }
}
