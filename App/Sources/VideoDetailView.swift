// VideoDetailView.swift
//
// A pushed detail screen, Set List style: circular back button + category pill + an ellipsis
// menu, big Archivo title, the category payload (recipe / track / code / film) under micro
// headers in the category color, and the ink pill TikTok action alone at the foot. The
// per-video "Analyse again" lives in that menu, where a repair belongs; the pipeline stage
// list that used to sit above the actions is gone — it was a troubleshooting aid, and the
// Import screen still shows the run as a whole.
//
// Film is the one category that skips the embedded player: `FilmSection`'s poster strip stands
// in for `WatchSection`, and the action pill below reads "WATCH ON TIKTOK" instead of "OPEN IN
// TIKTOK" — nothing on this screen plays the clip itself, so "open" undersold what the button does.
//
// A coding save is laid out as a result, not a clip: the point (the code note's summary) in a
// forest card under the byline, a before/after pair when the analysis wrote one, the items as
// tappable takeaways, the clip as a compact row, link rows, tag chips that filter the Code tab,
// and "more like this". Its TikTok action is a circled arrow in the top bar, so the foot holds
// nothing for the floating tab bar to cover.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct VideoDetailView: View {
    @Environment(\.modelContext) private var context
    /// The row as pushed. The pipeline writes on its own ModelContext, and an instance this
    /// context already holds stays stale until it fetches again — so the screen renders the
    /// queried copy below, which SwiftData refreshes after every save from any context. Before
    /// this, a re-run finished and the screen showed nothing.
    private let given: Video
    @Query private var live: [Video]
    private var video: Video { live.first ?? given }

    @State private var isRerunning = false
    /// Takeaway rows whose detail is open, by index into `CodeData.items`.
    @State private var expanded: Set<Int> = []
    /// Every coding save, for "More like this"; newest first, so the two shown are the freshest.
    @Query(filter: #Predicate<Video> { $0.categoryRaw == "coding" },
           sort: \Video.bookmarkedAt, order: .reverse) private var codingSaves: [Video]

    init(video: Video) {
        given = video
        let id = video.videoID
        _live = Query(filter: #Predicate<Video> { $0.videoID == id })
    }

    @AppStorage("boxBaseURL") private var boxBaseURL = BoxDefaults.baseURL
    @AppStorage("chatModel") private var chatModel = BoxDefaults.chatModel
    @AppStorage("whisperModel") private var whisperModel = BoxDefaults.whisperModel

    private var tint: Color { video.category?.color ?? .categoryOther }
    private var isCoding: Bool { video.category == .coding }
    /// The analysed code note of a coding save; nil sends the save down the generic layout.
    private var codingPage: CodeData? { isCoding ? video.codeNote : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                header
                if let code = codingPage {
                    codingBody(code)
                } else {
                    if video.category == .film {
                        FilmSection(video: video, tint: tint)
                    } else {
                        WatchSection(video: video, tint: tint)
                    }
                    if let recipe = video.recipe { recipeSection(recipe) }
                    if !video.music.isEmpty { musicSection(video.music) }
                    if !video.buys.isEmpty { buysSection(video.buys) }
                    textSection
                    if !isCoding { actions }
                }
            }
            .padding(.horizontal, 20)
            // The coding page has no pill at the foot, so its last row must clear the tab bar.
            .padding(.bottom, isCoding ? stashTabBarClearance : 24)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 8) {
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
            if isCoding { openInTikTok }
            moreMenu
        }
        .padding(.top, 8)
    }

    /// The coding page's way out to the clip: a circled outbound arrow up here, reachable from
    /// anywhere on the page, instead of the ink pill at the foot.
    private var openInTikTok: some View {
        Link(destination: video.url) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .overlay(Circle().strokeBorder(tint, lineWidth: 1.5))
                .minTapTarget()
        }
        .accessibilityLabel("Open in \(TikTokLink.isInstagram(video.url) ? "Instagram" : "TikTok")")
    }

    /// Re-analysing one save is a repair, not something a reader reaches for, so it sits under
    /// an ellipsis up here instead of competing with the TikTok pill at the foot of the screen.
    /// The ellipsis becomes a spinner while the run is in flight — the menu closes on tap, and
    /// the work is otherwise invisible until the payload below changes under the reader.
    @ViewBuilder
    private var moreMenu: some View {
        if !isDemoLibrary {
            Menu {
                Button { rerun() } label: {
                    Label("Analyse again", systemImage: "arrow.clockwise")
                }
                .disabled(isRerunning || budgetSpent)
                // A re-analysis fetches the transcript again, which costs a unit. Saying so
                // beside the greyed-out item beats an item that refuses taps without a reason.
                if let budgetNote { Text(budgetNote) }
            } label: {
                Group {
                    if isRerunning {
                        ProgressView().controlSize(.small).tint(.stashInk)
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.stashInk.opacity(0.75))
                    }
                }
                .minTapTarget()
            }
            .accessibilityLabel("More actions")
        }
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
            // The coding page says it in "The point" instead.
            if codingPage == nil, !video.summary.isEmpty || !video.caption.isEmpty {
                Text(video.summary.isEmpty ? video.caption : video.summary)
                    .font(.archivo(14))
                    .foregroundStyle(Color.stashInk.opacity(0.85))
                    .lineSpacing(4)
                    .padding(.top, 12)
            }
            if codingPage == nil, !video.topics.isEmpty {
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

    /// A section break has to out-measure the 18pt gap between the rows inside a section,
    /// or the screen reads as one undivided list.
    private func sectionHeader(_ text: String) -> some View {
        Micro(text: text, size: 11, tracking: 2, color: tint)
            .padding(.top, 34)
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

    // MARK: - Coding page

    @ViewBuilder
    private func codingBody(_ code: CodeData) -> some View {
        pointCard(code)
        if let before = code.before, let after = code.after {
            beforeAfter(before, after)
        }
        if !code.items.isEmpty {
            sectionHeader(code.headline(checked: code.items.filter(video.isChecked).count))
            VStack(spacing: 0) {
                ForEach(Array(code.items.enumerated()), id: \.offset) { index, item in
                    codeItemRow(index: index, item: item, shape: code.shape, links: code.links)
                    if code.shape != .howto {
                        Divider().overlay(Color.stashInk.opacity(0.12))
                    }
                }
            }
            .padding(.top, 4)
        }
        WatchSection(video: video, tint: tint, compact: true)
            .padding(.top, 24)
        if !code.links.isEmpty { linkRows(code.links) }
        if !code.techTags.isEmpty { tagChips(code.techTags) }
        if !video.buys.isEmpty { buysSection(video.buys) }
        if let related = related(code) { moreLikeThis(related.tag, related.saves) }
    }

    /// What you get if you take this on board: the code note's summary, promoted to the top.
    @ViewBuilder
    private func pointCard(_ code: CodeData) -> some View {
        let text = code.summary.isEmpty ? video.summary : code.summary
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Micro(text: "The point", size: 10, tracking: 2.2, color: .stashOnAccent.opacity(0.7))
                Text(text)
                    .font(.archivo(15, .heavy))
                    .foregroundStyle(Color.stashOnAccent)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .stashCard(fill: tint)
            .padding(.top, 16)
        }
    }

    /// How it is done without this, how it is done with it; the "with" column wears the tint.
    private func beforeAfter(_ before: String, _ after: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            contrastColumn("Without it", before, highlighted: false)
            contrastColumn("With it", after, highlighted: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 10)
    }

    private func contrastColumn(_ label: String, _ text: String, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Micro(text: label, size: 9.5, tracking: 1.8,
                  color: highlighted ? tint : .stashInk.opacity(0.62))
            Text(text)
                .font(.archivo(12.5))
                .foregroundStyle(Color.stashInk.opacity(highlighted ? 1 : 0.62))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(highlighted ? tint : Color.stashInk.opacity(0.28),
                              lineWidth: highlighted ? 1.5 : 1.2)
        )
    }

    /// One row per item, laid out by `CodeData.shape`: tick boxes for a checklist, a link per
    /// tool, and for a howto or an explainer a takeaway row — the square marker (a number on a
    /// howto, where the order is the content), the text, and a chevron that opens the detail
    /// inline. No mono, no copy button: nobody runs these from a phone.
    @ViewBuilder
    private func codeItemRow(index: Int, item: CodeItem, shape: CodeData.Kind, links: [URL]) -> some View {
        switch shape {
        case .checklist:
            let checked = video.isChecked(item)
            Button {
                video.setChecked(!checked, for: item)
                try? context.save()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Rectangle().strokeBorder(tint, lineWidth: 1.5)
                        if checked {
                            Rectangle().fill(tint)
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .black))
                                .foregroundStyle(Color.stashOnAccent)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                    codeItemText(item, dimmed: checked)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(checked ? "Checked" : "Not checked")
        case .tools:
            Link(destination: toolURL(for: item, in: links)) {
                HStack(alignment: .top, spacing: 12) {
                    codeItemText(item, dimmed: false)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tint)
                        .padding(.top, 2)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Open \(item.text)")
        case .howto, .explainer:
            let open = expanded.contains(index)
            let hasDetail = !item.detail.isEmpty
            // Not `.disabled` for a row with no detail: that dims the label, and a plain row
            // is not a greyed-out one.
            Button {
                guard hasDetail else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    if open { expanded.remove(index) } else { expanded.insert(index) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    if shape == .howto {
                        Text("\(index + 1)")
                            .font(.archivo(19, .heavy))
                            .foregroundStyle(tint)
                            .frame(width: 22, alignment: .leading)
                    } else {
                        Rectangle().fill(tint).frame(width: 8, height: 8)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.text)
                            .font(.archivo(14, .semibold))
                            .foregroundStyle(Color.stashInk)
                            .multilineTextAlignment(.leading)
                        if open, hasDetail {
                            Text(item.detail)
                                .font(.archivo(12.5))
                                .foregroundStyle(Color.stashInk.opacity(0.6))
                                .lineSpacing(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.stashInk.opacity(0.4))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(hasDetail ? (open ? "Hides the detail" : "Shows the detail") : "")
        }
    }

    private func codeItemText(_ item: CodeItem, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text)
                .font(.archivo(14, .semibold))
                .foregroundStyle(Color.stashInk.opacity(dimmed ? 0.45 : 1))
                .strikethrough(dimmed, color: Color.stashInk.opacity(0.45))
                .multilineTextAlignment(.leading)
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.archivo(12.5))
                    .foregroundStyle(Color.stashInk.opacity(dimmed ? 0.35 : 0.6))
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A stated link that names the tool wins; otherwise a GitHub search for it.
    // ponytail: no repo resolver — a search page is one tap from the repo and needs no API key.
    private func toolURL(for item: CodeItem, in links: [URL]) -> URL {
        let needle = item.text.lowercased().filter { !$0.isWhitespace }
        if !needle.isEmpty,
           let link = links.first(where: { $0.absoluteString.lowercased().contains(needle) }) {
            return link
        }
        var parts = URLComponents(string: "https://github.com/search")!
        parts.queryItems = [URLQueryItem(name: "q", value: item.text),
                            URLQueryItem(name: "type", value: "repositories")]
        return parts.url!
    }

    /// The links the post states, one row each: the page's name over its host.
    private func linkRows(_ links: [URL]) -> some View {
        VStack(spacing: 0) {
            ForEach(links, id: \.self) { link in
                Link(destination: link) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pageName(link))
                                .font(.archivo(14, .bold))
                                .foregroundStyle(Color.stashInk)
                                .lineLimit(1)
                            Text(host(link))
                                .font(.archivo(12))
                                .foregroundStyle(Color.stashInk.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(tint)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Open \(pageName(link)) on \(host(link))")
                Divider().overlay(Color.stashInk.opacity(0.12))
            }
        }
        .padding(.top, 10)
    }

    // ponytail: the last path component is the page name; fetching <title> is a request per link for a label.
    private func pageName(_ url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty || name == "/" ? host(url) : name.removingPercentEncoding ?? name
    }

    private func host(_ url: URL) -> String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The tech tags as chips; a tap lands on the Code tab filtered to that tag.
    private func tagChips(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    TopicChip(label: tag, isOn: false) {
                        PipelineCenter.shared.codeFocus = tag
                        PipelineCenter.shared.codeFocusCount += 1
                    }
                    .accessibilityHint("Shows every coding save tagged \(tag)")
                }
            }
        }
        .padding(.top, 12)
    }

    /// Up to two other coding saves sharing a tag — the first of this save's tags that any
    /// other save carries, so the section says which tag it is about.
    private func related(_ code: CodeData) -> (tag: String, saves: [Video])? {
        let others = codingSaves.filter { $0.videoID != video.videoID && !$0.unavailable }
        guard !others.isEmpty else { return nil }
        let tagged = others.map { ($0, $0.codeNote?.techTags ?? []) }
        for tag in code.techTags {
            let hits = tagged.filter { $0.1.contains(tag) }.prefix(2).map(\.0)
            if !hits.isEmpty { return (tag, Array(hits)) }
        }
        return nil
    }

    @ViewBuilder
    private func moreLikeThis(_ tag: String, _ saves: [Video]) -> some View {
        sectionHeader("More like this · \(tag)")
        VStack(spacing: 0) {
            ForEach(saves, id: \.videoID) { other in
                NavigationLink { VideoDetailView(video: other) } label: {
                    HStack(spacing: 10) {
                        Thumbnail(url: other.thumbnailURL, category: .coding, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(other.rowTitle)
                                .font(.archivo(14, .bold))
                                .foregroundStyle(Color.stashInk)
                                .lineLimit(1)
                            Text([tag, other.codeNote?.shelfLabel].compactMap { $0 }.joined(separator: " · "))
                                .font(.archivo(12))
                                .foregroundStyle(Color.stashInk.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.stashInk.opacity(0.4))
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.stashInk.opacity(0.12))
            }
        }
        .padding(.top, 4)
    }

    /// What this save is selling. Shown on every category, because that is what `BuyPick` is —
    /// the sneakers in a style video belong here as much as the keyboard in a coding one.
    /// Each row opens the pick's page (`HaulDetailView`): live offers, the pick's own frame,
    /// and the store searches that used to be the only action here.
    @ViewBuilder
    private func buysSection(_ buys: [BuyPick]) -> some View {
        sectionHeader(buys.count == 1 ? "In this video" : "\(buys.count) things in this video")
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(buys.enumerated()), id: \.offset) { index, pick in
                if index > 0 { Divider().overlay(Color.stashInk.opacity(0.12)) }
                NavigationLink {
                    HaulDetailView(video: video, pick: pick, pickIndex: index)
                } label: {
                    HStack(spacing: 10) {
                        if let frame = PickFrameStore.shared.frame(videoID: video.videoID,
                                                                   pickIndex: index) {
                            Thumbnail(url: frame, category: video.category, size: 36)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pick.name)
                                .font(.archivo(14, .bold))
                                .foregroundStyle(Color.stashInk)
                                .multilineTextAlignment(.leading)
                            if !pick.kind.isEmpty || !pick.price.isEmpty {
                                Text([pick.kind, pick.price].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.archivo(12))
                                    .foregroundStyle(Color.stashInk.opacity(0.55))
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "bag")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.stashHaul)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(pick.name)")
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

    /// One action, since "Analyse again" moved up into the top bar's menu: the pill is now the
    /// only thing at the foot of the screen, which is the only thing a reader wants there.
    private var actions: some View {
        Link(destination: video.url) {
            HStack(spacing: 9) {
                Image(systemName: video.category == .film ? "arrow.up.right.square" : "play.rectangle")
                    .font(.system(size: 15, weight: .semibold))
                Text(video.category == .film ? "WATCH ON TIKTOK" : "OPEN IN TIKTOK")
                    .font(.archivo(13, .heavy))
                    .tracking(0.8)
            }
            .foregroundStyle(Color.stashOnInk)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(Color.stashInk, in: Capsule())
        }
        .padding(.top, 26)
    }

    /// Read through the singleton rather than stored: `VideoDetailView` takes its video as a
    /// non-defaulted `let`, so any extra private stored property would drag the memberwise
    /// initializer down to `private` and break every call site. Observation still tracks it —
    /// the read happens inside `body`.
    private var quota: Quota? { StashSession.shared.quota }
    private var budgetSpent: Bool { quota?.remaining == 0 }

    /// Why "Analyse again" is greyed out, in the words the menu shows beside it.
    private var budgetNote: String? {
        guard let quota, quota.remaining == 0 else { return nil }
        return "No budget left · \(quota.monthLimit) more on "
            + quota.monthResetDate.formatted(date: .abbreviated, time: .omitted)
    }

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
            // This one save only. `processAll` drains every pending video in the library — on a
            // half-imported library that was hundreds of TikTok fetches and a hot phone per tap.
            await runner.process(videoID: video.videoID)
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
