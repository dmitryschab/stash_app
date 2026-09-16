// HaulDetailView.swift
//
// A product from a saved video, with personal shopping state and country-specific offers.
// Artwork comes from the original video; store prices remain separate from mentioned prices.

import SwiftUI
import SwiftData
import TikTokBrainKit

struct HaulDetailView: View {
    let video: Video
    let pick: BuyPick
    let pickIndex: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.stashTabBarHidden) private var tabBarHidden
    @AppStorage(DeliveryAddress.countryKey) private var country = DeliveryAddress.phoneCountry
    @State private var editingCountry = false
    @State private var saveError: String?

    private var offerStore: OfferStore { OfferStore.shared }
    private var shoppingState: HaulPickState? { video.haulState(for: pick) }
    private var isRefreshing: Bool { offerStore.isRefreshing(name: pick.name, country: country) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                productHeader
                shoppingActions
                offerSection
                searchMenu
                sourceCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { tabBarHidden.wrappedValue = true }
        .onDisappear { tabBarHidden.wrappedValue = false }
        .task(id: country) {
            await offerStore.resolve(name: pick.name, kind: pick.kind, country: country)
            if case .offers(let offers, _) = offerStore.state(name: pick.name, country: country),
               let image = offers.compactMap(\.imageURL).first {
                await PickFrameStore.shared.storeProductImage(from: image, videoID: video.videoID,
                                                              pickIndex: pickIndex)
            }
            // The prices may have failed; the picture must not fail with them.
            await PickFrameStore.shared.ensureProductImage(for: pick, videoID: video.videoID,
                                                           pickIndex: pickIndex)
        }
        .task { await PickFrameStore.shared.ensureFrames(for: video) }
        .sheet(isPresented: $editingCountry) { DeliveryAddressSheet() }
    }

    // MARK: - Product

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.2))
                    // Without this the glyph is the only target: the circle is a background,
                    // which never takes a touch. A rectangle rather than the circle it draws,
                    // because a thumb aimed at the ring lands on the corner as often as inside
                    // it, and a miss on the only way off the page reads as a dead button.
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
            Spacer(minLength: 0)
            Text(HaulCategory.category(for: pick).label.uppercased())
                .font(.archivo(11, .bold))
                .foregroundStyle(Color.stashHaul)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Capsule().strokeBorder(Color.stashHaul, lineWidth: 1.2))
            Spacer(minLength: 0)
            Menu {
                if let link = pick.link {
                    Link("Open the link from the video", destination: link)
                }
                Link("Open original video", destination: video.url)
                ShareLink(item: pick.link ?? video.url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button { retryOffers() } label: {
                    Label("Refresh prices", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.2))
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Product options")
        }
        .foregroundStyle(Color.stashInk)
        .buttonStyle(.plain)
        .padding(.top, 8)
    }

    /// What the picture actually is, said plainly: the seller's own photo when one arrived,
    /// the video's frame when it did not. Claiming the wrong one is how a page stops being
    /// believed — and `revision` is read so the line changes the moment a photo lands.
    private var artworkSource: String {
        _ = PickFrameStore.shared.revision
        return PickFrames.cachedProductImage(videoID: video.videoID, pickIndex: pickIndex) != nil
            ? "From the shop" : "From the saved video"
    }

    private var productHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HaulProductArtwork(video: video, pickIndex: pickIndex)
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityLabel(artworkSource)
                .padding(.top, 14)
            Text(artworkSource)
                .font(.archivo(11))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            Text(pick.name)
                .font(.archivo(28, .heavy))
                .foregroundStyle(Color.stashInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            if !pick.kind.isEmpty {
                Text(pick.kind.prefix(1).uppercased() + pick.kind.dropFirst())
                    .font(.archivo(16))
                    .foregroundStyle(Color.stashInk.opacity(0.7))
                    .padding(.top, 4)
            }
        }
    }

    private var shoppingActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    wantButton
                    Rectangle().fill(Color.stashInk.opacity(0.18)).frame(width: 1, height: 24)
                    boughtButton
                }
                VStack(spacing: 8) {
                    wantButton
                    boughtButton
                }
            }
            if let saveError {
                Text(saveError)
                    .font(.archivo(13))
                    .foregroundStyle(Color.categoryRecipe)
                    .accessibilityLabel(saveError)
            }
        }
        .padding(.top, 14)
    }

    private var wantButton: some View {
        Button { setShoppingState(shoppingState == .want ? nil : .want) } label: {
            Label("Want", systemImage: shoppingState == .want ? "bookmark.fill" : "bookmark")
                .font(.archivo(14, .semibold))
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
                .background(shoppingState == .want ? Color.stashHaul.opacity(0.12) : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.stashHaul, lineWidth: 1.3))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.stashInk)
        .accessibilityValue(shoppingState == .want ? "Selected" : "Not selected")
        .accessibilityHint("Save this product to your wanted items")
    }

    private var boughtButton: some View {
        Button { setShoppingState(shoppingState == .bought ? nil : .bought) } label: {
            HStack(spacing: 7) {
                if shoppingState == .bought { Image(systemName: "checkmark.circle.fill") }
                Text(shoppingState == .bought ? "Bought" : "Mark as bought")
            }
            .font(.archivo(14, .semibold))
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity)
            .frame(minHeight: 44)
            .padding(.horizontal, 10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.stashInk)
        .accessibilityValue(shoppingState == .bought ? "Selected" : "Not selected")
        .accessibilityHint(shoppingState == .bought ? "Remove the bought status" : "Mark this product as bought")
    }

    private func setShoppingState(_ state: HaulPickState?) {
        let previous = shoppingState
        video.setHaulState(state, for: pick)
        do {
            try modelContext.save()
            saveError = nil
        } catch {
            video.setHaulState(previous, for: pick)
            saveError = "Couldn’t save this change. Please try again."
        }
    }

    // MARK: - Offers

    private var countryName: String {
        Locale.current.localizedString(forRegionCode: country) ?? country
    }

    private var countryButton: some View {
        Button { editingCountry = true } label: {
            HStack(spacing: 7) {
                Text(countryName)
                    .font(.archivo(13, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.stashInk)
        .accessibilityLabel("Shopping country: \(countryName)")
        .accessibilityHint("Change country to find local stores and prices")
    }

    @ViewBuilder
    private var offerSection: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                offerHeading.fixedSize()
                Spacer(minLength: 0)
                countryButton.fixedSize()
            }
            VStack(alignment: .leading, spacing: 0) {
                offerHeading
                countryButton
            }
        }
        .padding(.top, 12)

        switch offerStore.state(name: pick.name, country: country) {
        case .checking:
            VStack(spacing: 10) {
                ForEach(0..<2, id: \.self) { _ in ShimmerBlock().frame(height: 48) }
            }
            .padding(.top, 6)
            Text("Checking stores in \(countryName)…")
                .font(.archivo(12))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .padding(.top, 8)
            mentionedPrice
        case .offers(let offers, let checkedAt) where !offers.isEmpty:
            offerCard(offers)
            Text(priceNote(checkedAt: checkedAt))
                .font(.archivo(11))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            refreshStatus
            if let first = offers.first {
                Link(destination: first.url) {
                    HStack(spacing: 8) {
                        Text("View at \(first.merchant)")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.archivo(15, .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.stashOnInk)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.stashInk, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            }
        case .offers(_, let checkedAt):
            miss(title: "No offers found in \(countryName)",
                 message: "Try the store searches below or choose another country.")
            Text(priceNote(checkedAt: checkedAt))
                .font(.archivo(11))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .padding(.top, 8)
            retryButton
        case .unavailable:
            miss(title: "Couldn’t check prices right now",
                 message: "You can still search stores or open the original link.")
            mentionedPrice
            retryButton
        }
    }

    private var offerHeading: some View {
        Text("Where to buy")
            .font(.archivo(20, .heavy))
            .foregroundStyle(Color.stashInk)
            .accessibilityAddTraits(.isHeader)
    }

    private var mentionedPrice: some View {
        Group {
            if !pick.price.isEmpty {
                Text("Mentioned in video: \(pick.price)")
                    .font(.archivo(12))
                    .foregroundStyle(Color.stashInk.opacity(0.6))
                    .padding(.top, 8)
            }
        }
    }

    private func priceNote(checkedAt: Date) -> String {
        let checked = "Checked \(checkedAt.formatted(.relative(presentation: .named)))"
        return pick.price.isEmpty ? checked : "\(checked) · Mentioned in video: \(pick.price)"
    }

    @ViewBuilder
    private var refreshStatus: some View {
        if isRefreshing {
            Text("Refreshing prices…")
                .font(.archivo(11))
                .foregroundStyle(Color.stashInk.opacity(0.6))
                .padding(.top, 5)
        } else if offerStore.refreshFailed(name: pick.name, country: country) {
            Text("Couldn’t refresh prices. The last offers are still available.")
                .font(.archivo(12))
                .foregroundStyle(Color.stashInk.opacity(0.7))
                .padding(.top, 8)
            retryButton
        }
    }

    private func offerCard(_ offers: [HaulOffer]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(offers.enumerated()), id: \.offset) { index, offer in
                if index > 0 { Divider().overlay(Color.stashInk.opacity(0.12)) }
                Link(destination: offer.url) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            merchantMark(offer)
                            merchantName(offer)
                            Spacer(minLength: 4)
                            offerPrice(offer).fixedSize()
                        }
                        HStack(alignment: .top, spacing: 12) {
                            merchantMark(offer)
                            VStack(alignment: .leading, spacing: 8) {
                                merchantName(offer)
                                offerPrice(offer)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(minHeight: 44)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("View at \(offer.merchant), \(offer.price), \(shopLine(offer))")
            }
        }
        .padding(.horizontal, 14)
        .background(Color.stashSurface.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.stashHaul, lineWidth: 1.2))
        .padding(.top, 3)
    }

    private func merchantMark(_ offer: HaulOffer) -> some View {
        Text(String(offer.merchant.prefix(1)).uppercased())
            .font(.archivo(19, .heavy))
            .foregroundStyle(Color.stashInk)
            .frame(width: 34, height: 38)
            .background(Color.stashSurface, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }

    private func merchantName(_ offer: HaulOffer) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(offer.merchant)
                .font(.archivo(14, .bold))
                .foregroundStyle(Color.stashInk)
            Text(shopLine(offer))
                .font(.archivo(11))
                .foregroundStyle(Color.stashInk.opacity(0.6))
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func offerPrice(_ offer: HaulOffer) -> some View {
        HStack(spacing: 12) {
            Text(offer.price)
                .font(.archivo(16, .bold))
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(Color.stashInk)
    }

    private func shopLine(_ offer: HaulOffer) -> String {
        let host = (offer.url.host() ?? "").replacingOccurrences(of: "www.", with: "")
        return offer.kind == .brand ? "Brand store · \(host)" : host
    }

    private func miss(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.archivo(15, .bold))
                .foregroundStyle(Color.stashInk)
            Text(message)
                .font(.archivo(13))
                .foregroundStyle(Color.stashInk.opacity(0.65))
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.stashSurface, in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 6)
    }

    private var retryButton: some View {
        Button { retryOffers() } label: {
            Label(isRefreshing ? "Checking prices…" : "Try again", systemImage: "arrow.clockwise")
                .font(.archivo(13, .semibold))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.stashHaul)
        .disabled(isRefreshing)
    }

    private func retryOffers() {
        Task { await offerStore.resolve(name: pick.name, kind: pick.kind, country: country, force: true) }
    }

    private var searchMenu: some View {
        Menu {
            ForEach(Shop.allCases, id: \.self) { shop in
                if let url = shop.searchURL(for: pick.name, region: country) {
                    Link(destination: url) { Label("Search \(shop.label)", systemImage: "magnifyingglass") }
                }
            }
            if let link = pick.link {
                Link("Open the link from the video", destination: link)
            }
        } label: {
            Text("Search other stores")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.top, 4)
    }

    // MARK: - Source

    private var sourceCard: some View {
        NavigationLink { VideoDetailView(video: video) } label: {
            HStack(spacing: 10) {
                Thumbnail(url: video.thumbnailURL, category: video.category, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.author.isEmpty ? "From your saved video" : "From @\(video.author)")
                        .font(.archivo(12, .bold))
                    Text(video.rowTitle)
                        .font(.archivo(11))
                        .foregroundStyle(Color.stashInk.opacity(0.65))
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .horizontal) {
                    Label("Watch", systemImage: "play.circle")
                        .font(.archivo(12, .semibold))
                        .fixedSize()
                    Image(systemName: "play.circle")
                        .font(.system(size: 26, weight: .regular))
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            .foregroundStyle(Color.stashInk)
            .padding(10)
            .background(Color.stashSurface.opacity(0.4), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.stashInk.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Watch \(video.rowTitle)\(video.author.isEmpty ? "" : " by @\(video.author)")")
        .padding(.top, 8)
    }
}

// MARK: - Shopping country

/// The country keys stay compatible with existing offer lookups and account cleanup.
/// The legacy street-address key is retained only so it can be removed.
enum DeliveryAddress {
    static let addressKey = "haulDeliveryAddress"
    static let countryKey = "haulDeliveryCountry"

    static var phoneCountry: String { Locale.current.region?.identifier ?? "DE" }
    static var country: String { UserDefaults.standard.string(forKey: countryKey) ?? phoneCountry }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: addressKey)
        UserDefaults.standard.removeObject(forKey: countryKey)
    }

    static let countries: [(code: String, name: String)] = Locale.Region.isoRegions
        .map(\.identifier)
        .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
        .compactMap { code in Locale.current.localizedString(forRegionCode: code).map { (code, $0) } }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
}

struct DeliveryAddressSheet: View {
    @AppStorage(DeliveryAddress.countryKey) private var savedCountry = DeliveryAddress.phoneCountry
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var countries: [(code: String, name: String)] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return DeliveryAddress.countries }
        return DeliveryAddress.countries.filter {
            $0.name.localizedStandardContains(query) || $0.code.localizedStandardContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(countries, id: \.code) { country in
                        Button {
                            savedCountry = country.code
                            PipelineCenter.shared.backfillOffers()   // the new country has no answers yet
                            UserDefaults.standard.removeObject(forKey: DeliveryAddress.addressKey)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Text(country.name)
                                    .font(.archivo(15, .semibold))
                                Spacer(minLength: 0)
                                if savedCountry == country.code {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                            }
                            .foregroundStyle(Color.stashInk)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(savedCountry == country.code ? "Selected" : "")
                        .listRowBackground(Color.stashSurface)
                    }
                } header: {
                    Text("Find stores and prices for your country")
                        .font(.archivo(12))
                        .textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.stashBackground)
            .overlay {
                if countries.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search countries")
            .navigationTitle("Shopping country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.stashInk)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
    private var failed: Set<String> = []     // session-only; an explicit retry clears it
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

    func isRefreshing(name: String, country: String) -> Bool {
        inflight.contains(Self.key(name: name, country: country))
    }

    func refreshFailed(name: String, country: String) -> Bool {
        failed.contains(Self.key(name: name, country: country))
    }

    /// Returns the failure, when there was one, so the library sweep can tell "this pick"
    /// from "the whole day" (the cap, offline, signed out).
    @discardableResult
    func resolve(name: String, kind: String, country: String, force: Bool = false) async -> Error? {
        let key = Self.key(name: name, country: country)
        if !force, let entry = entries[key], Date().timeIntervalSince(entry.fetchedAt) < Self.maxAge {
            return nil
        }
        guard !inflight.contains(key) else { return nil }
        failed.remove(key)
        inflight.insert(key)
        defer { inflight.remove(key) }
        do {
            let offers = try await HaulOffersClient(config: PipelineCenter.currentConfig())
                .offers(name: name, kind: kind, country: country)
            entries[key] = Entry(offers: offers, fetchedAt: Date())
            failed.remove(key)
            try? JSONEncoder().encode(entries).write(to: Self.cacheURL)
            return nil
        } catch {
            // A stale answer, when one exists, outranks an error screen; only a pick with no
            // answer at all shows the miss state.
            failed.insert(key)
            return error
        }
    }

    // MARK: - Library sweep

    private var sweepTask: Task<Void, Never>?
    /// A sweep asked for while one was running fetched its list before those saves landed —
    /// same problem, same fix, as `PipelineCenter.embeddingsPending`.
    private var sweepPending = false
    /// Each lookup is a live web search on the box (up to 100 s); three abreast keeps a
    /// fresh library's first answers arriving in minutes without hammering the box.
    private static let sweepWidth = 3

    /// Looks up every pick that has no answer yet, newest save first, so a pick page opens
    /// with its shops already there instead of "Checking stores…". The box caps lookups at
    /// 100 a day per account, so the order is what decides which picks get answered first;
    /// the sweep stops at the cap, offline or signed out, and the next foreground resumes.
    /// Stale answers are left alone — day-old prices still open the page, and the page
    /// refreshes them itself — so the cap is spent on picks nobody has priced yet.
    func prefetchLibrary(container: ModelContainer) {
        guard sweepTask == nil else {
            sweepPending = true
            return
        }
        let country = DeliveryAddress.country
        sweepTask = Task { [weak self] in
            let picks = await Task.detached(priority: .utility) { () -> [(name: String, kind: String)] in
                let context = ModelContext(container)
                let videos = (try? context.fetch(FetchDescriptor<Video>(
                    sortBy: [SortDescriptor(\.bookmarkedAt, order: .reverse)]))) ?? []
                return videos.flatMap { $0.buys.map { (name: $0.name, kind: $0.kind) } }
            }.value
            guard let self else { return }
            var seen: Set<String> = []
            let pending = picks.filter {
                let key = Self.key(name: $0.name, country: country)
                return seen.insert(key).inserted && entries[key] == nil && !failed.contains(key)
            }
            var next = pending.makeIterator()
            var stopped = false
            await withTaskGroup(of: Error?.self) { group in
                for _ in 0..<Self.sweepWidth {
                    guard let pick = next.next() else { break }
                    group.addTask { await self.resolve(name: pick.name, kind: pick.kind, country: country) }
                }
                while let error = await group.next() {
                    if Self.endsSweep(error) { stopped = true }   // let the in-flight ones land
                    guard !stopped, let pick = next.next() else { continue }
                    group.addTask { await self.resolve(name: pick.name, kind: pick.kind, country: country) }
                }
            }
            sweepTask = nil
            if sweepPending {
                sweepPending = false
                if !stopped { prefetchLibrary(container: container) }
            }
        }
    }

    /// The failures the next pick cannot fix: the day's cap (429), no network, no session.
    /// A 502 is one search that went wrong, and the next pick may well be fine.
    private static func endsSweep(_ error: Error?) -> Bool {
        guard let error else { return false }
        if error is StashError { return true }
        switch error as? BoxError {
        case .badResponse(429), .unreachable: return true
        default: return false
        }
    }
}

// MARK: - Pick frame store

/// Keeps a per-pick picture, two ways. The shop's catalog photo arrives with the pick's offers
/// and is downloaded once (`storeProductImage`). Failing that, a frame is extracted out of the
/// video itself: one download covers every pick the video carries, frames are re-sampled
/// exactly the way the OCR pass samples them, read with the same Vision OCR, and each pick
/// keeps the frame whose on-screen text names it (`PickFrames.frameIndex`). That costs one
/// deep-pass unit per video, once. Both persist beside the covers; the photo wins.
@MainActor @Observable
final class PickFrameStore {
    static let shared = PickFrameStore()

    private var attempted: Set<String> = []   // session-only; a failed video retries next launch
    private var attemptedImages: Set<String> = []
    private var attemptedPhotos: Set<String> = []
    /// Bumped when new pictures land, so rows drawn from the filesystem re-read it.
    private(set) var revision = 0

    func frame(videoID: String, pickIndex: Int) -> URL? {
        _ = revision   // register with Observation: a stored picture must repaint stale rows
        return PickFrames.picture(videoID: videoID, pickIndex: pickIndex)
    }

    /// Downloads the shop's product photo into the pick's slot, once per pick per launch.
    func storeProductImage(from remote: URL, videoID: String, pickIndex: Int) async {
        let slot = "\(videoID)-\(pickIndex)"
        guard PickFrames.cachedProductImage(videoID: videoID, pickIndex: pickIndex) == nil,
              !attemptedImages.contains(slot) else { return }
        attemptedImages.insert(slot)
        guard let (data, _) = try? await URLSession.shared.data(from: remote),
              PickFrames.storeProductImage(data, videoID: videoID, pickIndex: pickIndex) != nil
        else { return }
        revision += 1
    }

    /// Asks the box for the pick's catalog photo when the offers did not carry one — a picture
    /// of the thing from whoever sells it, which is what the page should show even on a day the
    /// price search is down. Once per pick per launch; a pick nobody photographs keeps its frame.
    func ensureProductImage(for pick: BuyPick, videoID: String, pickIndex: Int) async {
        guard StashSession.shared.isSignedIn,
              PickFrames.cachedProductImage(videoID: videoID, pickIndex: pickIndex) == nil,
              !attemptedPhotos.contains("\(videoID)-\(pickIndex)") else { return }
        attemptedPhotos.insert("\(videoID)-\(pickIndex)")
        guard let remote = try? await HaulOffersClient(config: PipelineCenter.currentConfig())
            .photo(name: pick.name, kind: pick.kind, link: pick.link) else { return }
        await storeProductImage(from: remote, videoID: videoID, pickIndex: pickIndex)
    }

    func ensureFrames(for video: Video) async {
        let videoID = video.videoID
        let picks = video.buys.enumerated().map { ($0.offset, $0.element.name) }
        guard StashSession.shared.isSignedIn, !picks.isEmpty,
              !attempted.contains(videoID), !video.unavailable,
              picks.contains(where: { PickFrames.picture(videoID: videoID, pickIndex: $0.0) == nil })
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
                    guard PickFrames.picture(videoID: videoID, pickIndex: pickIndex) == nil,
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
