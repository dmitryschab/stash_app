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

/// What one deep-pass download yielded.
///
/// The download is the expensive part — a metered round trip through the box — so both reads of
/// the file come back together: the words burned into the frames, and the track playing under
/// them. Either half can be absent; a music video with nothing written on screen is exactly the
/// case the audio half exists for.
public struct DeepPass: Sendable {
    public var visualText: String?
    public var audioMatch: AudioMatch?

    public init(visualText: String? = nil, audioMatch: AudioMatch? = nil) {
        self.visualText = visualText
        self.audioMatch = audioMatch
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
        report(to: progress)
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
            report(to: progress)
        }
    }

    /// Reports library-wide progress (see `processedCounts`) rather than the per-pass
    /// drain counters, so the UI shows a stable "done of total-imported" that survives
    /// relaunches instead of restarting at zero on each pass or launch.
    private func report(to progress: @Sendable (Int, Int) -> Void) {
        if let counts = try? processedCounts() { progress(counts.done, counts.total) }
    }

    // MARK: - Queue selection

    public func pendingCount() throws -> Int {
        let videos = try ModelContext(container).fetch(FetchDescriptor<Video>())
        return videos.reduce(into: 0) { count, video in
            if isPending(video) { count += 1 }
        }
    }

    /// Library-wide UI progress: how many imported videos have finished their fast pass
    /// (enrich no longer `.pending` — classified, unavailable, or hard-failed) over the
    /// total imported. Monotonic and stable across relaunches, unlike the per-pass drain
    /// counters used to schedule work.
    /// ponytail: full fetch per call; fine at <=1200 videos, revisit if imports grow.
    public func processedCounts() throws -> (done: Int, total: Int) {
        let videos = try ModelContext(container).fetch(FetchDescriptor<Video>())
        let done = videos.reduce(into: 0) { count, video in
            if stageStates(video)[PipelineStage.enrich.rawValue] != .pending { count += 1 }
        }
        return (done, videos.count)
    }

    // MARK: - Re-analysis (taxonomy refresh)

    /// Re-runs ONLY the analyze stage for every already-classified, available video, using
    /// its stored caption/transcript/OCR — no re-enrich, no re-transcribe, so nothing that was
    /// fetched is lost. Used to re-bucket the library after the category set changes. I/O-bound
    /// analyzer calls overlap on the actor (like `processAll`); reports (done, total).
    public func reanalyzeAll(concurrency: Int = 4, progress: @escaping @Sendable (Int, Int) -> Void) async {
        let videos = (try? ModelContext(container).fetch(FetchDescriptor<Video>())) ?? []
        let ids = videos.filter { !$0.unavailable && !$0.categoryRaw.isEmpty }.map(\.videoID)
        let total = ids.count
        var done = 0
        progress(done, total)
        var iterator = ids.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, min(concurrency, total)) {
                if let id = iterator.next() { group.addTask { await self.reanalyzeOne(videoID: id) } }
            }
            for await _ in group {
                done += 1
                progress(done, total)
                if !Task.isCancelled, let id = iterator.next() {
                    group.addTask { await self.reanalyzeOne(videoID: id) }
                }
            }
        }
    }

    private func reanalyzeOne(videoID: String) async {
        let context = ModelContext(container)
        guard let video = try? context.fetch(
            FetchDescriptor<Video>(predicate: #Predicate { $0.videoID == videoID })).first else { return }
        let meta = VideoMeta(caption: video.caption, hashtags: video.hashtags,
                             author: video.author, thumbnailURL: video.thumbnailURL)
        guard let analysis = try? await deps.analyzer.analyze(
            meta: meta, transcript: video.transcript, ocrText: video.ocrText) else { return }
        // Drop stale payloads first so a video re-bucketed away from recipe/music/coding
        // doesn't keep showing the old card; applyAnalysis re-sets whichever one still applies.
        video.recipeJSON = nil
        video.trackJSON = nil
        video.musicJSON = nil
        video.codeJSON = nil
        video.buysJSON = nil
        await applyAnalysis(analysis, to: video)
        try? context.save()
    }

    // MARK: - Transcript backfill

    /// What a backfill run managed to do, so the UI can explain why it stopped.
    public struct BackfillResult: Sendable {
        public let filled: Int
        public let attempted: Int
        public let remaining: Int
        /// True when the run aborted instead of reaching the end of its queue.
        public let stoppedEarly: Bool
        /// Set when the abort was the per-user budget rather than throttling/network, so the
        /// caller can say "budget used up, N more on the 1st" instead of "try again in an hour".
        public let quotaExhausted: Quota?

        init(filled: Int, attempted: Int, remaining: Int,
             stoppedEarly: Bool, quotaExhausted: Quota? = nil) {
            self.filled = filled
            self.attempted = attempted
            self.remaining = remaining
            self.stoppedEarly = stoppedEarly
            self.quotaExhausted = quotaExhausted
        }
    }

    /// Give up after this many transcripts fail back-to-back: the free Whisper tier caps
    /// audio-seconds per rolling hour, and once it is exhausted every further call just burns
    /// a request. Stopping leaves the rest for the next run.
    private static let throttleAbortThreshold = 5

    private enum BackfillOutcome { case filled, empty, failed, quotaExhausted(Quota) }

    /// Fetches transcripts for videos that have none, then re-analyzes each one it fills so the
    /// summary and category come from the audio instead of the caption alone.
    ///
    /// Deliberately serial: the original bulk import fired hundreds of transcript calls at once
    /// and blew the hourly quota, which is what made ~60% of them fail. Running one at a time
    /// stays under the cap. The run is resumable — it only picks videos that still have no
    /// transcript and were not already attempted — so calling it again continues where it left off.
    /// `only` narrows the run to specific videos. A share-imported video needs its transcript
    /// straight away, and without the filter that one save would drag the entire library's
    /// backlog along with it and spend the whole month's budget on the first share.
    public func backfillTranscripts(
        limit: Int = Int.max,
        only: Set<String>? = nil,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> BackfillResult {
        let all = (try? ModelContext(container).fetch(
            FetchDescriptor<Video>(sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]))) ?? []
        let targets = all.filter { video in
            !video.unavailable && video.transcript == nil
                && stageStates(video)[PipelineStage.transcribe.rawValue] != .done
                && (only?.contains(video.videoID) ?? true)
        }.map(\.videoID).prefix(limit)

        let total = targets.count
        var filled = 0, attempted = 0, consecutiveFailures = 0
        progress(0, total)
        for id in targets {
            if Task.isCancelled { break }
            attempted += 1
            switch await backfillOne(videoID: id) {
            case .filled: filled += 1; consecutiveFailures = 0
            case .empty: consecutiveFailures = 0   // music/no speech is a normal result
            case .failed: consecutiveFailures += 1
            case .quotaExhausted(let quota):
                // No point burning the rest of the queue: every further call returns 402.
                return BackfillResult(filled: filled, attempted: attempted,
                                      remaining: total - attempted, stoppedEarly: true,
                                      quotaExhausted: quota)
            }
            progress(attempted, total)
            if consecutiveFailures >= Self.throttleAbortThreshold {
                return BackfillResult(filled: filled, attempted: attempted,
                                      remaining: total - attempted, stoppedEarly: true)
            }
        }
        return BackfillResult(filled: filled, attempted: attempted,
                              remaining: total - attempted, stoppedEarly: false)
    }

    private func backfillOne(videoID: String) async -> BackfillOutcome {
        let context = ModelContext(container)
        guard let video = try? context.fetch(
            FetchDescriptor<Video>(predicate: #Predicate { $0.videoID == videoID })).first else { return .failed }

        let fetched: String?
        do {
            fetched = try await deps.transcriber.transcript(for: video.url)
        } catch StashError.quotaExhausted(let quota) {
            return .quotaExhausted(quota)
        } catch {
            return .failed   // left untouched, so the next run retries it
        }

        // Mark the stage done either way: a no-speech video must not be retried forever.
        var stages = stageStates(video)
        stages[PipelineStage.transcribe.rawValue] = .done
        store(stages, on: video)

        guard let fetched, !fetched.isEmpty else {
            try? context.save()
            return .empty
        }

        video.transcript = fetched
        let meta = VideoMeta(caption: video.caption, hashtags: video.hashtags,
                             author: video.author, thumbnailURL: video.thumbnailURL)
        if let analysis = try? await deps.analyzer.analyze(
            meta: meta, transcript: fetched, ocrText: video.ocrText) {
            video.recipeJSON = nil
            video.trackJSON = nil
            video.musicJSON = nil
            video.codeJSON = nil
            video.buysJSON = nil
            await applyAnalysis(analysis, to: video)
        }
        try? context.save()
        return .filled
    }

    // MARK: - Visual text backfill

    /// Extracts on-screen text for videos that have none, then re-analyzes each one with it, and
    /// folds in whatever the audio identified along the way.
    ///
    /// On TikTok the words burned into the frame are often the actual content (recipe steps,
    /// list items, auto-captions), and Vision OCR is free and unmetered — unlike cloud Whisper,
    /// which is why this needs none of the transcript backfill's hourly pacing. The real cost is
    /// bandwidth for the video download, which `deepPass` owns; it receives the video's ID and
    /// URL and returns everything read off that one file (see `DeepPass`).
    ///
    /// Resumable on the same terms as the transcript backfill: only videos with no stored
    /// `ocrText` whose ocr stage is not already done are picked up.
    /// `only` narrows the run to specific videos; see `backfillTranscripts(limit:only:progress:)`.
    public func backfillVisualText(
        limit: Int = Int.max,
        only: Set<String>? = nil,
        deepPass: @escaping @Sendable (String, URL) async throws -> DeepPass,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async -> BackfillResult {
        let all = (try? ModelContext(container).fetch(
            FetchDescriptor<Video>(sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]))) ?? []
        let targets = all.filter { video in
            guard !video.unavailable, only?.contains(video.videoID) ?? true else { return false }
            if let existing = video.ocrText {
                // Read before frame grouping shipped. The flat pool it produced is what made the
                // analyzer pair titles with the wrong artists, so it is worth the unit to re-read.
                return !existing.hasPrefix(FrameReader.frameMarker)
            }
            return stageStates(video)[PipelineStage.ocr.rawValue] != .done
        }.map(\.videoID).prefix(limit)

        let total = targets.count
        var filled = 0, attempted = 0, consecutiveFailures = 0
        progress(0, total)
        for id in targets {
            if Task.isCancelled { break }
            attempted += 1
            switch await backfillVisualOne(videoID: id, deepPass: deepPass) {
            case .filled: filled += 1; consecutiveFailures = 0
            case .empty: consecutiveFailures = 0   // no on-screen text is a normal result
            case .failed: consecutiveFailures += 1
            case .quotaExhausted(let quota):
                // Each download costs a quota unit, so there is nothing left to spend.
                return BackfillResult(filled: filled, attempted: attempted,
                                      remaining: total - attempted, stoppedEarly: true,
                                      quotaExhausted: quota)
            }
            progress(attempted, total)
            // Repeated failures here mean the box or the network is down, not a quota — either
            // way, continuing just burns bandwidth, so leave the rest for the next run.
            if consecutiveFailures >= Self.throttleAbortThreshold {
                return BackfillResult(filled: filled, attempted: attempted,
                                      remaining: total - attempted, stoppedEarly: true)
            }
        }
        return BackfillResult(filled: filled, attempted: attempted,
                              remaining: total - attempted, stoppedEarly: false)
    }

    private func backfillVisualOne(
        videoID: String,
        deepPass: @escaping @Sendable (String, URL) async throws -> DeepPass
    ) async -> BackfillOutcome {
        let context = ModelContext(container)
        guard let video = try? context.fetch(
            FetchDescriptor<Video>(predicate: #Predicate { $0.videoID == videoID })).first else { return .failed }

        let pass: DeepPass
        do {
            pass = try await deepPass(video.videoID, video.url)
        } catch StashError.quotaExhausted(let quota) {
            return .quotaExhausted(quota)
        } catch {
            return .failed   // untouched, so the next run retries it
        }

        var stages = stageStates(video)
        stages[PipelineStage.ocr.rawValue] = .done
        store(stages, on: video)

        var outcome = BackfillOutcome.empty
        if let recognized = pass.visualText, !recognized.isEmpty {
            // Always stored in the marked format, whatever produced it. The re-read above is
            // triggered by the absence of a marker, so text stored without one would be re-read on
            // every run — a silent, unbounded spend. A reader that returns one unmarked blob is
            // recorded as a single frame, which is what it is.
            let marked = recognized.hasPrefix(FrameReader.frameMarker) ? recognized : "[1] " + recognized
            video.ocrText = marked
            let meta = VideoMeta(caption: video.caption, hashtags: video.hashtags,
                                 author: video.author, thumbnailURL: video.thumbnailURL)
            if let analysis = try? await deps.analyzer.analyze(
                meta: meta, transcript: video.transcript, ocrText: marked) {
                video.recipeJSON = nil
                video.trackJSON = nil
                video.musicJSON = nil
                video.codeJSON = nil
                video.buysJSON = nil
                await applyAnalysis(analysis, to: video)
            }
            outcome = .filled
        }

        // After the re-analysis, so the match lands on the picks the video ends the pass with —
        // and outside the branch above, because a music video with nothing written on screen is
        // precisely the kind the audio has something to say about.
        await apply(pass.audioMatch, to: video)
        try? context.save()
        return outcome
    }

    /// Folds a recognised track into the video's picks: the artist the model was forbidden to
    /// guess, or the one pick a music video with none should have had. See `AudioMatch.merged`
    /// for what it refuses to touch.
    private func apply(_ match: AudioMatch?, to video: Video) async {
        guard let match else { return }
        var stored = video.musicJSON
            .flatMap { try? JSONDecoder().decode([MusicPick].self, from: $0) } ?? []
        // A legacy single-track save counts as the video's picks, or the rule that protects an
        // artist the model gave would not protect that one. Writing `musicJSON` below retires the
        // old shape, exactly as re-analysis does.
        if stored.isEmpty,
           let legacy = video.trackJSON.flatMap({ try? JSONDecoder().decode(TrackData.self, from: $0) }),
           !legacy.title.isEmpty {
            stored = [MusicPick(kind: .track, title: legacy.title,
                                artist: legacy.artist, link: legacy.universalLink)]
        }
        guard let merged = match.merged(
            into: stored, category: Category(rawValue: video.categoryRaw) ?? .other) else { return }

        // Re-resolve, because a pick that just gained an artist can now be looked up properly.
        // `resolve` overwrites every link outright, so keep the old one wherever the new lookup
        // came back empty — a catalogue that is down today must not erase yesterday's answer.
        let resolved = await deps.musicResolver.resolve(merged)
        let kept = zip(resolved, merged).map { new, old -> MusicPick in
            var new = new
            if new.link == nil { new.link = old.link }
            return new
        }
        video.musicJSON = try? JSONEncoder().encode(kept)
        video.trackJSON = nil
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
        if !analysis.music.isEmpty {
            // Best-effort: a pick nothing matched keeps a nil link and shows as a plain name.
            let resolved = await deps.musicResolver.resolve(analysis.music)
            video.musicJSON = try? encoder.encode(resolved)
            video.trackJSON = nil   // the legacy single-track copy is now stale
        }
        if let code = analysis.code {
            video.codeJSON = try? encoder.encode(code)
        }
        if !analysis.buys.isEmpty {
            video.buysJSON = try? encoder.encode(analysis.buys)
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
        // A session that expired mid-drain is temporary — park the stage so it re-runs after
        // the user signs back in. An exhausted budget is a hard failure for this pass.
        if case StashError.unauthenticated = error { return .awaitingBox }
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
