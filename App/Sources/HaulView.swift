import SwiftUI
import SwiftData
import TikTokBrainKit

private struct HaulItem: Identifiable {
    let video: Video
    let pick: BuyPick
    let index: Int
    var id: String { "\(video.videoID)#\(index)" }
}

private struct HaulSave: Identifiable {
    let video: Video
    var items: [HaulItem]
    var id: String { video.videoID }
}

private enum HaulSort: String, CaseIterable {
    case recent = "Recent", oldest = "Oldest", name = "Name"
}

private enum HaulStatusFilter: String, CaseIterable {
    case all = "All finds", want = "Want", bought = "Bought"
    func includes(_ item: HaulItem) -> Bool {
        switch self {
        case .all: true
        case .want: item.video.haulState(for: item.pick) == .want
        case .bought: item.video.haulState(for: item.pick) == .bought
        }
    }
}

struct HaulView: View {
    @Query(sort: \Video.bookmarkedAt, order: .reverse) private var videos: [Video]
    @State private var query = ""
    @State private var category: HaulCategory?
    @State private var status = HaulStatusFilter.all
    @State private var sort = HaulSort.recent
    @State private var showingFilters = false
    @FocusState private var searching: Bool

    private var items: [HaulItem] {
        videos.filter { !$0.needsLook }.flatMap { video in
            video.buys.enumerated().map { HaulItem(video: video, pick: $1, index: $0) }
        }
    }

    private var shown: [HaulItem] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return items.filter { item in
            guard category == nil || HaulCategory.category(for: item.pick) == category,
                  status.includes(item) else { return false }
            let searchable = [item.pick.name, item.pick.kind, item.video.author,
                              "@" + item.video.author, item.video.rowTitle].joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }
    }

    private var saves: [HaulSave] {
        var result: [HaulSave] = []
        var indices: [String: Int] = [:]
        for item in shown {
            if let index = indices[item.video.videoID] { result[index].items.append(item) }
            else {
                indices[item.video.videoID] = result.count
                result.append(HaulSave(video: item.video, items: [item]))
            }
        }
        switch sort {
        case .recent: break
        case .oldest: result.reverse()
        case .name:
            result.sort {
                let left = $0.items.first?.pick.name ?? $0.video.rowTitle
                let right = $1.items.first?.pick.name ?? $1.video.rowTitle
                let comparison = left.localizedStandardCompare(right)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
        }
        return result
    }

    private var categories: [HaulCategory] {
        let present = Set(items.map { HaulCategory.category(for: $0.pick) })
        return HaulCategory.allCases.filter { present.contains($0) }
    }

    private var rowCategories: [HaulCategory] {
        var result = Array(categories.prefix(3))
        if let category, !result.contains(category) {
            if result.count == 3 { result.removeLast() }
            result.append(category)
        }
        return result
    }

    private var filtering: Bool {
        category != nil || status != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            StashScrollView(tab: .haul) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    searchField
                    categoryChips
                    if items.isEmpty { emptyLibrary }
                    else {
                        listHeading
                        if shown.isEmpty { noResults }
                        else {
                            LazyVStack(spacing: 12) {
                                ForEach(saves) { save in
                                    HaulSaveCard(save: save, searching: !query.isEmpty)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, stashTabBarClearance)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color.stashBackground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingFilters) { filterSheet }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            StashHeader(title: "Haul", trailing: "\(items.count) products · \(Set(items.map(\.video.videoID)).count) saves")
            Text("Good finds, all together.")
                .font(.archivo(15, .semibold)).foregroundStyle(Color.stashInk)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium)).accessibilityHidden(true)
            TextField("Search your finds", text: $query)
                .font(.archivo(15))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($searching)
                .onSubmit { searching = false }
                .accessibilityIdentifier("haul.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                }.accessibilityLabel("Clear search")
            }
        }
        .foregroundStyle(Color.stashInk)
        .padding(.leading, 16).padding(.trailing, query.isEmpty ? 16 : 2)
        .frame(minHeight: 48)
        .background(Color.stashSurface, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.stashHaul, lineWidth: 1.25))
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("All", selected: category == nil) { category = nil }
                ForEach(rowCategories) { item in
                    chip(item.label, selected: category == item) {
                        category = category == item ? nil : item
                    }
                }
                chip("More", selected: status != .all, symbol: "slider.horizontal.3") {
                    searching = false
                    showingFilters = true
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, symbol: String? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
            }
            .font(.archivo(13, .semibold))
            .foregroundStyle(selected ? Color.stashOnInk : .stashInk)
            .padding(.horizontal, 17).frame(minHeight: 44)
            .background(selected ? Color.stashInk : .clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.stashInk : .stashHaul, lineWidth: 1.25))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var listHeading: some View {
        HStack {
            Text(status == .all ? "YOUR FINDS" : "\(status.rawValue.uppercased()) · \(shown.count)")
                .font(.archivo(11, .bold)).tracking(1.5)
            Spacer()
            Menu {
                Picker("Sort finds", selection: $sort) {
                    ForEach(HaulSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(sort.rawValue).font(.archivo(13))
                    Image(systemName: "arrow.down").font(.system(size: 11))
                }.frame(minHeight: 44)
            }
            .accessibilityLabel("Sort finds, \(sort.rawValue)")
        }
        .foregroundStyle(Color.stashInk).padding(.bottom, -12)
    }

    private var filterSheet: some View {
        NavigationStack {
            List {
                Section("Category") {
                    filterOption("All categories", selected: category == nil) { category = nil }
                    ForEach(categories) { item in
                        filterOption(item.label, selected: category == item) { category = item }
                    }
                }
                Section("Your shortlist") {
                    ForEach(HaulStatusFilter.allCases, id: \.self) { item in
                        filterOption(item.rawValue, selected: status == item) { status = item }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.stashBackground)
            .navigationTitle("Filter finds").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { category = nil; status = .all }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingFilters = false }
                }
            }
            .tint(.stashHaul)
        }
        .presentationDetents([.medium, .large])
    }

    private func filterOption(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.archivo(15))
                Spacer()
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .foregroundStyle(Color.stashInk).frame(minHeight: 32)
        }
        .listRowBackground(Color.stashSurface)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var emptyLibrary: some View {
        StashEmptyState(symbol: "bag", tint: .stashHaul, title: "Your finds start here",
                        message: videos.isEmpty
                            ? "Save a video with something you love. Its products will be waiting here."
                            : "Products named in your videos appear here as your saves are analyzed.",
                        offersImport: videos.isEmpty)
            .padding(.top, 28)
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(Color.stashHaul)
            Text("No matching finds").font(.archivo(20, .bold))
            Text("Try a product, brand, or creator, or change your filters.")
                .font(.archivo(14)).multilineTextAlignment(.center)
            if filtering {
                Button("Clear search and filters") { query = ""; category = nil; status = .all }
                    .font(.archivo(14, .semibold)).foregroundStyle(Color.stashHaul).frame(minHeight: 44)
            }
        }
        .foregroundStyle(Color.stashInk).frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}

private struct HaulSaveCard: View {
    let save: HaulSave
    let searching: Bool
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var grouped: Bool { save.video.buys.count > 1 }
    private var visibleItems: [HaulItem] {
        expanded || searching ? save.items : Array(save.items.prefix(2))
    }

    var body: some View {
        VStack(spacing: 0) {
            if grouped { sourceHeader }
            VStack(spacing: 0) {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { offset, item in
                    if offset > 0 { Divider().overlay(Color.stashHaul.opacity(0.15)) }
                    HaulProductRow(item: item, showCreator: !grouped)
                }
                if save.items.count > 2 && !searching {
                    Divider().overlay(Color.stashHaul.opacity(0.15))
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 8) {
                            Text(expanded ? "Show fewer products" : "View all \(save.items.count) products")
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        }
                        .font(.archivo(13, .semibold)).foregroundStyle(Color.stashInk)
                        .frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("haul.expand.\(save.id)")
                }
            }
            .padding(.horizontal, 12).background(Color.stashSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.stashHaul, lineWidth: 1.25))
    }

    private var sourceHeader: some View {
        HStack(spacing: 10) {
            NavigationLink { VideoDetailView(video: save.video) } label: {
                HStack(spacing: 10) {
                    HaulProductArtwork(video: save.video)
                        .frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(save.video.rowTitle).font(.archivo(15, .bold)).lineLimit(2)
                        Text(sourceLine).font(.archivo(12)).foregroundStyle(Color.stashOnAccent.opacity(0.85))
                    }.multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                ShareLink(item: save.video.url) { Label("Share source video", systemImage: "square.and.arrow.up") }
                Link(destination: save.video.url) { Label("Open in TikTok", systemImage: "arrow.up.right") }
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("More options for \(save.video.rowTitle)")
        }
        .foregroundStyle(Color.stashOnAccent)
        .padding(.leading, 12).padding(.trailing, 2).padding(.vertical, 12)
        .background(Color.stashHaul)
    }

    private var sourceLine: String {
        let count = save.items.count == save.video.buys.count
            ? "\(save.items.count) products" : "\(save.items.count) of \(save.video.buys.count) products"
        return [save.video.author.isEmpty ? "" : "@\(save.video.author)", count]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct HaulProductRow: View {
    let item: HaulItem
    let showCreator: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationLink {
            HaulDetailView(video: item.video, pick: item.pick, pickIndex: item.index)
        } label: {
            HStack(spacing: 13) {
                HaulProductArtwork(video: item.video, pickIndex: item.index)
                    .frame(width: typeSize.isAccessibilitySize ? 60 : 78, height: typeSize.isAccessibilitySize ? 60 : 78)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.pick.name).font(.archivo(16, .bold))
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2).foregroundStyle(Color.stashInk)
                    if showCreator && !item.video.author.isEmpty {
                        Text("@\(item.video.author)").font(.archivo(12.5)).foregroundStyle(Color.stashInk.opacity(0.7))
                    } else if !item.pick.kind.isEmpty {
                        Text(item.pick.kind.capitalized).font(.archivo(12.5)).foregroundStyle(Color.stashInk.opacity(0.7))
                    }
                    if !item.pick.price.isEmpty {
                        Text("Mentioned: \(item.pick.price)").font(.archivo(12)).foregroundStyle(Color.stashInk.opacity(0.7))
                    }
                    if let state = item.video.haulState(for: item.pick) {
                        Label(state == .want ? "Want" : "Bought", systemImage: state == .want ? "bookmark.fill" : "checkmark.circle.fill")
                            .font(.archivo(11, .semibold)).foregroundStyle(Color.stashHaul)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.stashHaul)
            }
            .multilineTextAlignment(.leading).padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("haul.product.\(item.id)")
    }
}

#Preview {
    HaulView().modelContainer(SampleData.previewContainer)
}
