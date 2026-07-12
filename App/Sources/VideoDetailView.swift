// VideoDetailView.swift
//
// A pushed detail screen, Set List style: circular back button + category pill, big Archivo
// title, the category payload (recipe / track / code) under micro headers in the category
// color, OCR/transcript disclosures, pipeline stage states, and the ink pill TikTok action
// with a per-video "re-run pipeline" underneath.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct VideoDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    let video: Video

    @State private var isRerunning = false

    @AppStorage("boxBaseURL") private var boxBaseURL = BoxDefaults.baseURL
    @AppStorage("chatModel") private var chatModel = BoxDefaults.chatModel
    @AppStorage("whisperModel") private var whisperModel = BoxDefaults.whisperModel

    private var tint: Color { video.category?.color ?? .categoryOther }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                header
                WatchSection(video: video, tint: tint)
                if let recipe = video.recipe { recipeSection(recipe) }
                if let track = video.track { trackSection(track) }
                if let code = video.codeNote { codeSection(code) }
                textSection
                pipelineSection
                actions
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.stashInk)
                    .frame(width: 36, height: 36)
                    .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")
            Spacer()
            if let category = video.category {
                CategoryBadge(category: category)
            } else if video.unavailable {
                Micro(text: "Unavailable", size: 10, tracking: 1.8, color: .categoryOther)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Capsule().strokeBorder(Color.categoryOther, lineWidth: 1.5))
            }
        }
        .padding(.top, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(video.rowTitle)
                .font(.archivo(28, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 16)
            Text(byline)
                .font(.archivo(12.5, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.5))
                .padding(.top, 8)
            if !video.summary.isEmpty || !video.caption.isEmpty {
                Text(video.summary.isEmpty ? video.caption : video.summary)
                    .font(.archivo(14))
                    .foregroundStyle(Color.stashInk.opacity(0.85))
                    .lineSpacing(4)
                    .padding(.top, 12)
            }
            if !video.topics.isEmpty {
                Text(video.topics.map { "#\($0)" }.joined(separator: " "))
                    .font(.archivo(12, .semibold))
                    .foregroundStyle(tint)
                    .padding(.top, 10)
            }
        }
    }

    private var byline: String {
        var parts: [String] = []
        if !video.author.isEmpty { parts.append("@\(video.author)") }
        parts.append("saved \(video.bookmarkedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    private func sectionHeader(_ text: String) -> some View {
        Micro(text: text, size: 11, tracking: 2, color: tint)
            .padding(.top, 20)
    }

    // MARK: - Payloads

    @ViewBuilder
    private func recipeSection(_ recipe: RecipeData) -> some View {
        if !recipe.ingredients.isEmpty {
            sectionHeader("Ingredients · \(recipe.ingredients.count)")
            VStack(spacing: 0) {
                ForEach(recipe.ingredients, id: \.self) { ingredient in
                    HStack(spacing: 12) {
                        Rectangle().fill(tint).frame(width: 8, height: 8)
                        Text(ingredient)
                            .font(.archivo(14, .semibold))
                            .foregroundStyle(Color.stashInk)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    Divider().overlay(Color.stashInk.opacity(0.12))
                }
            }
            .padding(.top, 4)
        }
        if !recipe.steps.isEmpty {
            sectionHeader("Method")
            VStack(spacing: 0) {
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.archivo(19, .heavy))
                            .foregroundStyle(tint)
                            .frame(width: 22, alignment: .leading)
                        Text(step)
                            .font(.archivo(14))
                            .foregroundStyle(Color.stashInk)
                            .lineSpacing(3)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func trackSection(_ track: TrackData) -> some View {
        sectionHeader("Track")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Thumbnail(url: video.thumbnailURL, category: .music, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.archivo(16, .bold))
                        .foregroundStyle(Color.stashInk)
                    Text(track.artist)
                        .font(.archivo(12.5))
                        .foregroundStyle(Color.stashInk.opacity(0.55))
                }
                Spacer(minLength: 0)
            }
            if let link = track.universalLink {
                Link(destination: link) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold))
                        Micro(text: "Open in your music app", size: 10, tracking: 1.2, color: .categoryMusic)
                    }
                    .foregroundStyle(Color.categoryMusic)
                }
                .padding(.top, 14)
            } else {
                Text("No universal link found for this track.")
                    .font(.archivo(12))
                    .foregroundStyle(Color.stashInk.opacity(0.5))
                    .padding(.top, 12)
            }
        }
        .stashOutlineCard()
        .padding(.top, 8)
    }

    @ViewBuilder
    private func codeSection(_ code: CodeData) -> some View {
        sectionHeader("Code note")
        VStack(alignment: .leading, spacing: 10) {
            if !code.summary.isEmpty {
                Text(code.summary)
                    .font(.archivo(14))
                    .foregroundStyle(Color.stashInk)
                    .lineSpacing(3)
            }
            ForEach(code.links, id: \.self) { link in
                Link(destination: link) {
                    HStack(spacing: 7) {
                        Image(systemName: "link").font(.system(size: 11, weight: .bold))
                        Text(link.host ?? link.absoluteString)
                            .font(.archivo(13, .semibold))
                    }
                    .foregroundStyle(Color.categoryCoding)
                }
            }
            if !code.techTags.isEmpty {
                Text(code.techTags.map { "#\($0)" }.joined(separator: " "))
                    .font(.archivo(12, .semibold))
                    .foregroundStyle(Color.categoryCoding)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashOutlineCard()
        .padding(.top, 8)
    }

    // MARK: - Text (OCR + transcript)

    @ViewBuilder
    private var textSection: some View {
        if let ocr = video.ocrText, !ocr.isEmpty {
            sectionHeader("On-screen text")
            Text(ocr)
                .font(.archivo(13))
                .foregroundStyle(Color.stashInk.opacity(0.85))
                .lineSpacing(3)
                .padding(.top, 6)
        }
        sectionHeader("Transcript")
        Group {
            if let transcript = video.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.archivo(13))
                    .foregroundStyle(Color.stashInk.opacity(0.85))
                    .lineSpacing(3)
            } else {
                Text("No transcript — the video may have no English audio.")
                    .font(.archivo(13))
                    .foregroundStyle(Color.stashInk.opacity(0.5))
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Pipeline

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("Pipeline")
            VStack(spacing: 0) {
                let states = video.stageStates
                ForEach(pipelineStageOrder, id: \.self) { stage in
                    let state = states[stage] ?? .pending
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(state.tint).frame(width: 22, height: 22)
                            Image(systemName: state == .done ? "checkmark" : state.symbol)
                                .font(.system(size: 10, weight: .heavy))
                                .foregroundStyle(Color.stashOnAccent)
                        }
                        Text(stage.capitalized)
                            .font(.archivo(15, .bold))
                            .foregroundStyle(Color.stashInk)
                        Spacer()
                        Micro(text: state.label, size: 10, tracking: 1.2, color: .stashInk.opacity(0.5))
                    }
                    .padding(.vertical, 11)
                    .padding(.horizontal, 16)
                    if stage != pipelineStageOrder.last {
                        Divider().overlay(Color.stashInk.opacity(0.12)).padding(.horizontal, 16)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.stashInk.opacity(0.9), lineWidth: 1.5)
            )
            .padding(.top, 8)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(spacing: 0) {
            Link(destination: video.url) {
                HStack(spacing: 9) {
                    Image(systemName: "play.rectangle").font(.system(size: 15, weight: .semibold))
                    Text("OPEN IN TIKTOK")
                        .font(.archivo(13, .heavy))
                        .tracking(0.8)
                }
                .foregroundStyle(Color.stashOnInk)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.stashInk, in: Capsule())
            }
            Button {
                rerun()
            } label: {
                HStack(spacing: 8) {
                    Micro(text: "Re-run pipeline", size: 11, tracking: 1.2, color: .stashInk.opacity(0.45))
                    if isRerunning { ProgressView().controlSize(.small).tint(.stashInk) }
                }
            }
            .buttonStyle(.plain)
            .disabled(isRerunning)
            .padding(.top, 14)
        }
        .padding(.top, 26)
    }

    private func rerun() {
        guard !isRerunning else { return }
        isRerunning = true
        video.resetStagesToPending()
        try? context.save()

        let container = context.container
        let config = makeBoxConfig(baseURL: boxBaseURL, chatModel: chatModel, whisperModel: whisperModel)
        Task {
            let runner = PipelineRunner(deps: PipelineCenter.makeDeps(config: config), container: container)
            await runner.processAll { _, _ in }
            await MainActor.run { isRerunning = false }
        }
    }
}

#Preview {
    NavigationStack {
        VideoDetailView(video: SampleData.makeSampleVideos()[0])
    }
    .modelContainer(SampleData.previewContainer)
}
