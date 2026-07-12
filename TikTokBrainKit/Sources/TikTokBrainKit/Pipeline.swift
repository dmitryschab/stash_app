// Pipeline.swift
//
// Task 7: the resumable per-video pipeline.
//
// `PipelineRunner` is an actor that owns a SwiftData `ModelContainer` and drives each
// ingested `Video` through the enrich → media → transcribe → ocr → analyze stages.
// Every stage is best-effort and independently caught: a `BoxError.unreachable` parks
// that stage in `awaitingBox` (retryable once the model box returns), while any other
// error marks it `failed`. Later stages always run with whatever earlier stages
// produced, so a missing transcript never blocks analysis. A video whose enrichment
// yields nothing usable is flagged `unavailable` and its remaining stages are skipped.
//
// Concrete collaborators are injected via `PipelineDeps` (protocols only), so the whole
// pipeline runs against fakes with an in-memory container in tests — no network, no box.

import Foundation
import SwiftData

/// Injected, protocol-typed collaborators for the pipeline. `ocr` is a closure so the App
/// can pass `FrameReader.recognizeText` and tests can pass a trivial stub.
public struct PipelineDeps: Sendable {
    public var enricher: any Enriching
    public var media: any MediaFetching
    public var transcriber: any Transcribing
    public var analyzer: any Analyzing
    public var musicResolver: any MusicLinkResolving
    public var ocr: @Sendable ([URL]) async throws -> String

    public init(
        enricher: any Enriching,
        media: any MediaFetching,
        transcriber: any Transcribing,
        analyzer: any Analyzing,
        musicResolver: any MusicLinkResolving,
        ocr: @escaping @Sendable ([URL]) async throws -> String
    ) {
        self.enricher = enricher
        self.media = media
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.musicResolver = musicResolver
        self.ocr = ocr
    }
}

/// The five pipeline stages. Raw values match the keys `Video` seeds into `stageStatesJSON`.
enum PipelineStage: String, CaseIterable {
    case enrich, media, transcribe, ocr, analyze
}

public actor PipelineRunner {
    private let deps: PipelineDeps
    private let container: ModelContainer

    public init(deps: PipelineDeps, container: ModelContainer) {
        self.deps = deps
        self.container = container
    }

    /// Inserts a `Video` for every bookmark whose id is not already stored. De-duplicates
    /// against existing rows and within the batch. Returns the number of new videos.
    public func ingest(bookmarks: [Bookmark]) async throws -> Int {
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<Video>())
        var knownIDs = Set(existing.map(\.videoID))
        var inserted = 0
        for bookmark in bookmarks where !knownIDs.contains(bookmark.id) {
            knownIDs.insert(bookmark.id)
            context.insert(Video(videoID: bookmark.id, url: bookmark.url, bookmarkedAt: bookmark.date))
            inserted += 1
        }
        try context.save()
        return inserted
    }

    /// Runs the next unprocessed video through every stage. Returns `false` when the queue is
    /// empty. Stage failures are recorded, not thrown; this only throws on a store error.
    @discardableResult
    public func processNext() async throws -> Bool {
        let context = ModelContext(container)
        guard let video = try nextPendingVideo(in: context) else { return false }
        inFlight.insert(video.videoID)
        defer { inFlight.remove(video.videoID) }
        await process(video)
        try context.save()
        return true
    }

    /// Number of videos processed concurrently. The shared Enricher's 1 s throttle
    /// still serializes TikTok page fetches; transcripts and analysis overlap.
    /// ponytail: fixed at 3 — box is a t3.micro; raise alongside the box.
    private static let concurrency = 3

    /// Drains the queue in passes until nothing more can make progress:
    /// pass 1 is the caption-first fast pass (enrich + analyze, transcript deferred),
    /// later passes backfill transcripts and re-analyze. Stops when the pending
    /// count stops shrinking (e.g. everything left is rate-limit-parked).
    /// Respects task cancellation between videos.
    public func processAll(progress: @escaping @Sendable (Int, Int) -> Void) async {
        var lastPending = Int.max
        while !Task.isCancelled {
            let pending = (try? pendingCount()) ?? 0
            guard pending > 0, pending < lastPending else { break }
            lastPending = pending
            passCompleted = 0
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<min(Self.concurrency, pending) {
                    group.addTask { await self.drainWorker(passTotal: pending, progress: progress) }
                }
            }
        }
    }

    private func drainWorker(passTotal: Int, progress: @Sendable (Int, Int) -> Void) async {
        while !Task.isCancelled, passCompleted < passTotal {
            guard (try? await processNext()) == true else { break }
            passCompleted += 1
            // Early workers may pipeline freshly-parked backfill within the same
            // pass; clamp so the UI never reports past the pass total.
            progress(min(passCompleted, passTotal), passTotal)
        }
    }

    // MARK: - Queue selection

    public func pendingCount() throws -> Int {
        let videos = try ModelContext(container).fetch(FetchDescriptor<Video>())
        return videos.reduce(into: 0) { count, video in
            if isPending(video) { count += 1 }
        }
    }

    /// Videos claimed by an in-flight worker; actor isolation makes claiming atomic.
    private var inFlight: Set<String> = []
    private var passCompleted = 0

    /// Fast-pass items (never enriched) come before transcript backfill, so a big
    /// import shows the whole classified library first and upgrades it after.
    private func nextPendingVideo(in context: ModelContext) throws -> Video? {
        let descriptor = FetchDescriptor<Video>(
            sortBy: [SortDescriptor(\.bookmarkedAt, order: .forward)])
        let candidates = try context.fetch(descriptor).filter {
            !inFlight.contains($0.videoID) && isPending($0)
        }
        return candidates.first {
            stageStates($0)[PipelineStage.enrich.rawValue] == .pending
        } ?? candidates.first
    }

    /// A video still needs processing while its first stage has never started, or
    /// while any stage is parked awaiting the box (throttled / box unreachable) —
    /// parked videos re-run on the next pass instead of requiring a manual re-run.
    private func isPending(_ video: Video) -> Bool {
        let stages = stageStates(video)
        if stages[PipelineStage.enrich.rawValue] == .pending { return true }
        return stages.values.contains(.awaitingBox)
    }

    // MARK: - Per-video pipeline

    private func process(_ video: Video) async {
        var stages = stageStates(video)
        func set(_ stage: PipelineStage, _ value: StageState) { stages[stage.rawValue] = value }
        defer { store(stages, on: video) }

        // Caption-first fast pass: a never-enriched video gets classified from its
        // caption immediately and its transcript deferred (parked as awaitingBox),
        // so a big import is browsable in minutes and upgrades itself afterwards.
        let fastPass = stages[PipelineStage.enrich.rawValue] == .pending

        // 1. Enrich — the only source of the stream URL and sound metadata.
        var meta = VideoMeta()
        var enriched = false
        do {
            meta = try await deps.enricher.enrich(video.url)
            apply(meta: meta, to: video)
            set(.enrich, .done)
            enriched = true
        } catch {
            set(.enrich, stageState(for: error))
        }

        // Nothing usable came back → deleted / private / region-locked. Flag and stop.
        guard enriched, !meta.isEffectivelyEmpty else {
            video.unavailable = true
            set(.media, .skipped)
            set(.transcribe, .skipped)
            set(.ocr, .skipped)
            set(.analyze, .skipped)
            return
        }

        // Thumbnail covers are signed, expiring URLs — grab the bytes now or never.
        if let cover = meta.thumbnailURL,
           let local = try? await ThumbnailStore.download(cover, videoID: video.videoID) {
            video.thumbnailURL = local
        }

        // 2. Media — retired: TikTok blocks in-app stream downloads; the box owns media.
        set(.media, .skipped)

        // 3. Transcribe — the box downloads audio and runs cloud Whisper (auto language).
        //    Deferred on the fast pass; nil is the normal music/no-speech outcome.
        if fastPass {
            set(.transcribe, .awaitingBox)  // backfill passes pick this up
        } else {
            do {
                video.transcript = try await deps.transcriber.transcript(for: video.url)
                set(.transcribe, .done)
            } catch {
                set(.transcribe, stageState(for: error))
            }
        }

        // 4. OCR — cut for the cloud release (frames would need a second server download);
        //    returns with preserve-and-rediscover keepsakes.
        set(.ocr, .skipped)

        // 5. Analyze — on the fast pass from the caption, on backfill with the transcript.
        //    A null backfill transcript adds nothing over the fast pass, so keep the
        //    existing analysis instead of paying for an identical model call.
        let needsAnalysis = fastPass || video.transcript != nil || video.categoryRaw.isEmpty
        if needsAnalysis {
            do {
                let analysis = try await deps.analyzer.analyze(
                    meta: meta, transcript: video.transcript, ocrText: video.ocrText)
                await applyAnalysis(analysis, to: video)
                set(.analyze, .done)
            } catch {
                set(.analyze, stageState(for: error))
            }
        } else {
            set(.analyze, .done)
        }
    }

    private func applyAnalysis(_ analysis: Analysis, to video: Video) async {
        video.categoryRaw = analysis.category.rawValue
        video.title = analysis.title
        video.summary = analysis.summary
        video.topics = analysis.topics

        let encoder = JSONEncoder()
        if let recipe = analysis.recipe {
            video.recipeJSON = try? encoder.encode(recipe)
        }
        if var track = analysis.track {
            // Resolve a universal song.link for music (best-effort; a failure just leaves it nil).
            if track.universalLink == nil {
                track.universalLink = try? await deps.musicResolver.universalLink(
                    title: track.title, artist: track.artist)
            }
            video.trackJSON = try? encoder.encode(track)
        }
        if let code = analysis.code {
            video.codeJSON = try? encoder.encode(code)
        }
    }

    // MARK: - Helpers

    private func apply(meta: VideoMeta, to video: Video) {
        video.caption = meta.caption
        video.hashtags = meta.hashtags
        video.author = meta.author
        video.thumbnailURL = meta.thumbnailURL
    }

    /// `BoxError.unreachable` parks a stage for a later retry; anything else is a hard failure.
    private func stageState(for error: Error) -> StageState {
        if let boxError = error as? BoxError {
            switch boxError {
            case .unreachable:
                return .awaitingBox
            case .badResponse(let status) where status == 429 || status >= 500:
                // Throttled (Groq free tier) or transient upstream failure — retryable.
                return .awaitingBox
            default:
                return .failed
            }
        }
        return .failed
    }

    private func stageStates(_ video: Video) -> [String: StageState] {
        (try? JSONDecoder().decode([String: StageState].self, from: video.stageStatesJSON)) ?? [:]
    }

    private func store(_ stages: [String: StageState], on video: Video) {
        if let data = try? JSONEncoder().encode(stages) { video.stageStatesJSON = data }
    }
}

private extension VideoMeta {
    /// True when enrichment produced nothing to work with (the video is likely gone/private).
    var isEffectivelyEmpty: Bool {
        caption.isEmpty && hashtags.isEmpty && author.isEmpty
            && thumbnailURL == nil && soundTitle == nil && soundArtist == nil && streamURL == nil
    }
}
