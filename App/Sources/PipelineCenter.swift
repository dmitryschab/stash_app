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

    private var container: ModelContainer?
    private var processingTask: Task<Void, Never>?
    private var extraTime: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Wiring

    /// Called once from the App with the shared SwiftData container.
    func configure(container: ModelContainer) {
        self.container = container
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

    /// Fresh import from a picked export file/folder, then drain the queue.
    func runImport(url: URL) async {
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

    /// Continues whatever is pending or parked — no file pick needed. Safe to call
    /// on every foreground/launch; does nothing when idle or already running.
    func resumePendingIfNeeded() {
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
        progress = (0, 0)
        await runner.processAll { done, total in
            Task { @MainActor [weak self] in self?.progress = (done, total) }
        }
    }

    // MARK: - Lifecycle (called from the App's scenePhase watcher)

    func appBecameActive() {
        endExtraTime()
        resumePendingIfNeeded()
    }

    func appEnteredBackground() {
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
