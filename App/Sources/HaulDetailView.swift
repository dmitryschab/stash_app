// HaulDetailView.swift
//
// The pick page: one thing a video tried to sell, opened from any pick row. Set List detail
// anatomy — back chevron + kind pill, big Archivo name, the save's art — and then the section
// the whole screen exists for: WHERE TO BUY, up to three live offers from shops that deliver
// to the reader's country, amazon storefront pinned first, tap opens the product page itself.
// The ranking comes off the box already ordered (haul_offers_api.py); this screen renders it
// and never re-sorts.
//
// Two stores feed it, both fill-in-later in the AlbumStore mold:
// - `OfferStore` asks POST /v1/haul/offers once per product+country per day, keeps a disk
//   snapshot so re-opens are instant and offline shows the last answer.
// - `PickFrameStore` gives multi-product videos per-pick pictures: it re-samples the video's
//   frames (the same download the OCR pass uses), matches each pick's name against the
//   on-screen text (`PickFrames`), and stores that frame as the pick's own thumbnail. A video
//   that never names its products on screen keeps the cover — honest, not broken.

import SwiftUI
import TikTokBrainKit

struct HaulDetailView: View {
    let video: Video
    let pick: BuyPick
    let pickIndex: Int

    private var offerStore: OfferStore { OfferStore.shared }
    private var country: String { Locale.current.region?.identifier ?? "DE" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                header
                sourceCard
                if let link = pick.link { videoLinkRow(link) }
                offerSection
                searchRow
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await offerStore.resolve(name: pick.name, kind: pick.kind, country: country) }
        .task { await PickFrameStore.shared.ensureFrames(for: video) }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            StashBackButton()
            Spacer()
            if !pick.kind.isEmpty {
                Micro(text: pick.kind, size: 10, tracking: 1.8, color: .stashOnAccent)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Color.stashHaul, in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pick.name)
                .font(.archivo(26, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 16)
            Text(byline)
                .font(.archivo(12.5, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.5))
                .padding(.top, 8)
        }
    }

    private var byline: String {
        var parts: [String] = []
        if !video.author.isEmpty { parts.append("@\(video.author)") }
        parts.append("saved \(video.bookmarkedAt.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    /// The save this pick came out of, wearing the pick's own frame once one is extracted.
    private var sourceCard: some View {
        NavigationLink { VideoDetailView(video: video) } label: {
            VStack(alignment: .leading, spacing: 0) {
                if !video.caption.isEmpty || !video.rowTitle.isEmpty {
                    Text(video.caption.isEmpty ? video.rowTitle : "\u{201C}\(video.caption)\u{201D}")
                        .font(.archivo(13, .semibold))
                        .foregroundStyle(Color.stashOnAccent.opacity(0.85))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                HStack {
                    Micro(text: "From this save", size: 9.5, tracking: 1.6,
                          color: .stashOnAccent.opacity(0.75))
                    Spacer()
                    Micro(text: "Watch ›", size: 9.5, tracking: 1.6, color: .stashOnAccent)
                }
                .padding(.top, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .stashArtCard(fill: .stashHaul, art: artURL)
        }
        .buttonStyle(.plain)
        .padding(.top, 14)
    }

    private var artURL: URL? {
        PickFrameStore.shared.frame(videoID: video.videoID, pickIndex: pickIndex)
            ?? video.thumbnailURL
    }

    private func videoLinkRow(_ link: URL) -> some View {
        Link(destination: link) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .bold))
                Text("Open the link from the video")
                    .font(.archivo(13, .semibold))
            }
            .foregroundStyle(Color.stashHaul)
        }
        .padding(.top, 16)
    }

    // MARK: - Offers

    @ViewBuilder
    private var offerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Micro(text: "Where to buy · ships to \(country)", size: 10, tracking: 2,
                  color: .stashHaul)
            Spacer()
            if !pick.price.isEmpty {
                Micro(text: "said in video · \(pick.price)", size: 9, tracking: 1.2,
                      color: .stashInk.opacity(0.45))
            }
        }
        .padding(.top, 22)

        switch offerStore.state(name: pick.name, country: country) {
        case .checking:
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in ShimmerBlock().frame(height: 34) }
            }
            .padding(.top, 10)
            Micro(text: "Checking amazon and the rest…", size: 8.5, tracking: 1.6,
                  color: .stashInk.opacity(0.4))
                .padding(.top, 8)
        case .offers(let offers, let checkedAt) where !offers.isEmpty:
            offerCard(offers)
            Micro(text: "prices checked \(checkedAt.formatted(.relative(presentation: .named)))",
                  size: 8.5, tracking: 1.6, color: .stashInk.opacity(0.4))
                .padding(.top, 8)
        case .offers:
            miss(title: "No shop found that ships this to \(countryName)",
                 message: "Nothing that delivers there showed a price for it. The searches below still work.")
        case .unavailable:
            miss(title: "Couldn't check prices right now",
                 message: "They'll be checked again next time this page opens.")
        }
    }

    private func offerCard(_ offers: [HaulOffer]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(offers.enumerated()), id: \.offset) { index, offer in
                if index > 0 { Divider().overlay(Color.stashInk.opacity(0.12)) }
                Link(destination: offer.url) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(offer.merchant)
                                .font(.archivo(15, .bold))
                                .foregroundStyle(Color.stashInk)
                                .lineLimit(1)
                            Micro(text: shopLine(offer), size: 8, tracking: 1.2,
                                  color: .stashInk.opacity(0.45))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(offer.price)
                            .font(.archivo(15, .semibold))
                            .foregroundStyle(Color.stashHaul)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.stashHaul.opacity(0.85))
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Buy at \(offer.merchant) for \(offer.price)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashOutlineCard(padding: 14)
        .padding(.top, 10)
    }

    /// The row's second line: the shop's host, plus what the slot means when it isn't obvious
    /// from the name — Amazon rows link straight to the product page, brand rows say whose
    /// store it is.
    private func shopLine(_ offer: HaulOffer) -> String {
        let host = (offer.url.host() ?? "").replacingOccurrences(of: "www.", with: "")
        switch offer.kind {
        case .amazon: return "\(host) · product page"
        case .brand: return "\(host) · brand store"
        case .other: return host
        }
    }

    private func miss(title: String, message: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.archivo(13, .bold))
                .foregroundStyle(Color.stashInk)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.archivo(11.5))
                .foregroundStyle(Color.stashInk.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
    }

    private var countryName: String {
        Locale.current.localizedString(forRegionCode: country) ?? country
    }

    /// The keyless escape hatch, always present and never the headline: the same two search
    /// links every pick had before this screen existed.
    private var searchRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Micro(text: "Or search yourself", size: 9, tracking: 2, color: .stashInk.opacity(0.45))
            HStack(spacing: 8) {
                ForEach(Shop.allCases, id: \.self) { shop in
                    if let url = shop.searchURL(for: pick.name) {
                        Link(destination: url) {
                            InfoChip(text: shop.label, systemImage: "magnifyingglass")
                        }
                    }
                }
            }
        }
        .padding(.top, 26)
    }
}

// MARK: - Offer store

/// Resolves picks to live offers through the Kit's `HaulOffersClient`, caching answers on
/// disk so a re-opened pick page renders instantly and offline shows the last answer. One
/// lookup per product+country per day — the box caches server-side on the same key, so even
/// that lookup is usually a cache read.
@MainActor @Observable
final class OfferStore {
    static let shared = OfferStore()

    struct Entry: Codable, Equatable {
        var offers: [HaulOffer]
        var fetchedAt: Date
    }

    enum State {
        case checking
        case offers([HaulOffer], checkedAt: Date)
        case unavailable
    }

    private(set) var entries: [String: Entry] = [:]
    private var failed: Set<String> = []     // session-only; retries next launch
    private var inflight: Set<String> = []
    private static let maxAge: TimeInterval = 24 * 60 * 60

    /// Not private: account deletion has to be able to remove it, and it holds shop offers
    /// derived from the user's saves.
    static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("HaulOfferCache.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.cacheURL),
           let snapshot = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = snapshot
        }
    }

    static func key(name: String, country: String) -> String {
        "\(country)|\(name.lowercased())"
    }

    /// The stored answer's top offer, cache-only — shelf rows read it, never fetch for it.
    func cachedTopOffer(name: String, country: String) -> HaulOffer? {
        entries[Self.key(name: name, country: country)]?.offers.first
    }

    func state(name: String, country: String) -> State {
        let key = Self.key(name: name, country: country)
        // A stale entry still answers — day-old prices beat a spinner — and `resolve`
        // refreshes it in the background.
        if let entry = entries[key] { return .offers(entry.offers, checkedAt: entry.fetchedAt) }
        return failed.contains(key) ? .unavailable : .checking
    }

    func resolve(name: String, kind: String, country: String) async {
        let key = Self.key(name: name, country: country)
        if let entry = entries[key], Date().timeIntervalSince(entry.fetchedAt) < Self.maxAge {
            return
        }
        guard !inflight.contains(key) else { return }
        inflight.insert(key)
        defer { inflight.remove(key) }
        do {
            let offers = try await HaulOffersClient(config: PipelineCenter.currentConfig())
                .offers(name: name, kind: kind, country: country)
            entries[key] = Entry(offers: offers, fetchedAt: Date())
            failed.remove(key)
            try? JSONEncoder().encode(entries).write(to: Self.cacheURL)
        } catch {
            // A stale answer, when one exists, outranks an error screen; only a pick with no
            // answer at all shows the miss state.
            if entries[key] == nil { failed.insert(key) }
        }
    }
}

// MARK: - Pick frame store

/// Extracts a per-pick picture out of the video itself. One download covers every pick the
/// video carries: frames are re-sampled exactly the way the OCR pass samples them, read with
/// the same Vision OCR, and each pick keeps the frame whose on-screen text names it
/// (`PickFrames.frameIndex`). Costs one deep-pass unit per video, once — the frames persist
/// beside the covers.
@MainActor @Observable
final class PickFrameStore {
    static let shared = PickFrameStore()

    private var attempted: Set<String> = []   // session-only; a failed video retries next launch
    /// Bumped when new frames land, so rows drawn from the filesystem re-read it.
    private(set) var revision = 0

    func frame(videoID: String, pickIndex: Int) -> URL? {
        _ = revision   // register with Observation: a stored frame must repaint stale rows
        return PickFrames.cachedFrame(videoID: videoID, pickIndex: pickIndex)
    }

    func ensureFrames(for video: Video) async {
        let videoID = video.videoID
        let picks = video.buys.enumerated().map { ($0.offset, $0.element.name) }
        guard StashSession.shared.isSignedIn, !picks.isEmpty,
              !attempted.contains(videoID), !video.unavailable,
              picks.contains(where: { PickFrames.cachedFrame(videoID: videoID, pickIndex: $0.0) == nil })
        else { return }
        attempted.insert(videoID)

        let config = PipelineCenter.currentConfig()
        let stored = await Task.detached(priority: .utility) { () -> Int in
            do {
                let file = try await BoxVideoDownload.temporaryFile(
                    videoID: videoID, baseURL: config.baseURL, auth: config.auth)
                defer { try? FileManager.default.removeItem(at: file) }
                // Twelve, to match the visual pass — the marker in any stored OCR text and the
                // index in this sample only agree while the sampling agrees.
                let frames = try await MediaFetcher(keyframeCount: 12).keyframes(fromLocalFile: file)
                defer { frames.forEach { try? FileManager.default.removeItem(at: $0) } }
                let text = try await FrameReader().recognizeText(in: frames)
                var count = 0
                for (pickIndex, name) in picks {
                    guard PickFrames.cachedFrame(videoID: videoID, pickIndex: pickIndex) == nil,
                          let frameIndex = PickFrames.frameIndex(for: name, in: text),
                          frames.indices.contains(frameIndex),
                          PickFrames.storeFrame(png: frames[frameIndex], videoID: videoID,
                                                pickIndex: pickIndex) != nil
                    else { continue }
                    count += 1
                }
                return count
            } catch {
                // Deleted video, photo post, daily cap — the cover stays, quietly.
                return 0
            }
        }.value
        if stored > 0 { revision += 1 }
    }
}

#Preview {
    NavigationStack {
        HaulDetailView(video: SampleData.makeSampleVideos()[0],
                       pick: BuyPick(name: "Logitech MX Master 4", kind: "mouse", price: "129 9€"),
                       pickIndex: 0)
    }
    .modelContainer(SampleData.previewContainer)
}
