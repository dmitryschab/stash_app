// VideoDetailView.swift
//
// A pushed detail screen, Set List style: circular back button + category pill, big Archivo
// title, the category payload (recipe / track / code) under micro headers in the category
// color, and the ink pill TikTok action with a per-video "re-run pipeline" underneath. The
// pipeline stage list that used to sit above the actions is gone — it was a troubleshooting
// aid, and the Import screen still shows the run as a whole.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct VideoDetailView: View {
    @Environment(\.modelContext) private var context
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
                if !video.music.isEmpty { musicSection(video.music) }
                if let code = video.codeNote { codeSection(code) }
                textSection
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
            StashBackButton()
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

    /// Every release the video recommends. One row each, whether that is one song or five
    /// albums — a row with no link is the honest outcome when the catalogue had nothing that
    /// was plausibly this release, not a rendering gap.
    @ViewBuilder
    private func musicSection(_ picks: [MusicPick]) -> some View {
        sectionHeader(picks.count == 1 ? "Track" : "\(picks.count) releases")
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(picks.enumerated()), id: \.offset) { index, pick in
                HStack(spacing: 13) {
                    if picks.count == 1 {
                        Thumbnail(url: video.thumbnailURL, category: .music, size: 46)
                    } else {
                        Text("\(index + 1)")
                            .font(.archivo(15, .black))
                            .foregroundStyle(Color.stashInk.opacity(pick.link != nil ? 0.9 : 0.4))
                            .frame(width: 22, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pick.title)
                            .font(.archivo(16, .bold))
                            .foregroundStyle(Color.stashInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(pickByline(pick))
                            .font(.archivo(12.5))
                            .foregroundStyle(Color.stashInk.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                    if let link = pick.link {
                        Link(destination: link) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.categoryMusic)
                        }
                        .accessibilityLabel("Open \(pick.title) in your music app")
                    }
                }
            }
        }
        .stashOutlineCard()
        .padding(.top, 8)
    }

    private func pickByline(_ pick: MusicPick) -> String {
        let kind = pick.kind == .album ? "Album" : "Track"
        let who = pick.artist.isEmpty ? "" : " · " + pick.artist
        return pick.link == nil ? kind + who + " · no match found" : kind + who
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

    /// Deliberately empty: the transcript and on-screen text are extraction signals, not
    /// something to read. They stay stored on the `Video` and stay in the search index — they
    /// just no longer take up the detail screen with raw machine output.
    @ViewBuilder
    private var textSection: some View { EmptyView() }

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
            if !isDemoLibrary {
                Button {
                    rerun()
                } label: {
                    HStack(spacing: 8) {
                        Micro(text: "Re-run pipeline", size: 11, tracking: 1.2, color: .stashInk.opacity(0.45))
                        if isRerunning { ProgressView().controlSize(.small).tint(.stashInk) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRerunning || budgetSpent)
                .opacity(budgetSpent ? 0.4 : 1)
                .padding(.top, 14)
                // A re-run fetches the transcript again, which costs a unit. Saying so up front
                // beats letting the stage come back "Failed" with no reason attached.
                if let quota, quota.remaining == 0 {
                    Micro(text: "No budget left · \(quota.monthLimit) more on "
                          + quota.monthResetDate.formatted(date: .abbreviated, time: .omitted),
                          size: 9.5, tracking: 1.2, color: .categoryOther)
                        .padding(.top, 8)
                }
            }
        }
        .padding(.top, 26)
    }

    /// Read through the singleton rather than stored: `VideoDetailView` takes its video as a
    /// non-defaulted `let`, so any extra private stored property would drag the memberwise
    /// initializer down to `private` and break every call site. Observation still tracks it —
    /// the read happens inside `body`.
    private var quota: Quota? { StashSession.shared.quota }
    private var budgetSpent: Bool { quota?.remaining == 0 }

    /// The demo library is invented content: its video ids do not resolve on TikTok, so a
    /// re-run enriches to nothing, and `PipelineRunner` reads that as deleted/private and sets
    /// `unavailable`. That drops the row out of Library, Cook, Music, Today and the mind map
    /// with no undo and no way back, so App Review could shrink its own demo library a tap at
    /// a time. Hide the control instead.
    ///
    /// ponytail: gated per account rather than per row — a demo account's library *is* the
    /// seeded one (RootView wipes any other on sign-in), and a per-row flag means a new
    /// `Video` property and a store migration for one button on one reviewer's device. The
    /// ceiling is a reviewer who also imports the sample export and then finds no re-run.
    private var isDemoLibrary: Bool { StashSession.shared.isDemoAccount }

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
