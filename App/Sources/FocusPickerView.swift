// FocusPickerView.swift
//
// Shown once per account, the first time an import's map has settled: the library's shape as
// a bar, and the biggest categories as chips. Up to three picks become tabs on the pill —
// three keeps every slot labelled (TabSlots: past five, labels go) — and the rest stay as
// Library shelves. Skipping is a choice too; the sheet never comes back on its own, and
// Settings keeps the full picker.

import SwiftUI
import TikTokBrainKit

struct FocusPickerView: View {
    let shares: [(category: Category, count: Int)]
    /// Called with the picks on "Set up my bar", with [] on Skip. The presenter marks the
    /// account either way.
    let onDone: ([Category]) -> Void

    @State private var picks: [Category] = []
    @State private var refused = false

    static let maxPicks = 3
    static let maxOffered = 6

    var body: some View {
        VStack(alignment: .leading, spacing: StashSpacing.group) {
            Micro(text: "YOUR LIBRARY", size: 11, tracking: 3.4, color: .stashInk)
                .padding(.top, 28)
            MapBar(shares: shares)
            Text("What do you want to find fast?")
                .font(.archivo(28, .heavy))
                .foregroundStyle(Color.stashInk)
            Text("Pick up to three. Each gets its own tab; everything else stays in Library.")
                .font(.archivo(14, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(Self.offered(shares), id: \.category) { share in
                    TopicChip(label: share.category.displayName, count: share.count, symbol: share.category.symbol,
                              unit: "saves", isOn: picks.contains(share.category)) {
                        toggle(share.category)
                    }
                }
            }
            if refused {
                Micro(text: "Three keeps every tab labelled; add more in Settings", size: 9.5, tracking: 1.2,
                      color: .categoryOther)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            StashPrimaryButton(title: "Set up my bar") { onDone(picks) }
                .disabled(picks.isEmpty)
                .opacity(picks.isEmpty ? 0.5 : 1)
            Button { onDone([]) } label: {
                Micro(text: "Skip", size: 11, tracking: 1.7, color: .stashInk.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .minTapTarget()
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.stashBackground.ignoresSafeArea())
        .animation(.easeOut(duration: 0.2), value: refused)
    }

    private func toggle(_ category: Category) {
        if let index = picks.firstIndex(of: category) {
            picks.remove(at: index)
            refused = false
        } else if picks.count < Self.maxPicks {
            picks.append(category)
            refused = false
        } else {
            refused = true
        }
    }

    // MARK: - Rules, as values

    /// The chips: the largest categories, never `other` (it has no tab), at most six.
    static func offered(_ shares: [(category: Category, count: Int)]) -> [(category: Category, count: Int)] {
        Array(shares.filter { $0.category != .other }.prefix(maxOffered))
    }

    /// The pill after a choice: Lately, the picks' tabs, Library. `TabSlots.encode` puts them
    /// in catalogue order whatever order they were tapped in.
    static func slots(for picks: [Category]) -> [StashTab] {
        [.today] + picks.prefix(maxPicks).compactMap(StashTab.tab(owning:)) + [.library]
    }

    /// Whether to present: not yet answered for this account, the import is the account's first
    /// (`eligible`), it is shaping the library, and the map has settled enough to mean
    /// something — twenty answers, or all of a small import — with a category worth offering.
    static func shouldShow(map: CloudImportMap?, shaping: Bool, picked: Bool, eligible: Bool) -> Bool {
        guard !picked, shaping, eligible, let map else { return false }
        guard map.done >= min(20, map.sampled) else { return false }
        return map.counts.contains { $0.key != .other && $0.value > 0 }
    }

    #if DEBUG
    static func selfTest() -> Bool {
        let shares: [(category: Category, count: Int)] = [(.coding, 230), (.recipe, 180), (.music, 90), (.other, 60),
                                                           (.home, 40), (.style, 20), (.film, 10), (.travel, 5)]
        let small = CloudImportMap(sampled: 3, done: 3, counts: [.coding: 3])
        let settling = CloudImportMap(sampled: 60, done: 19, counts: [.coding: 19])
        let settled = CloudImportMap(sampled: 60, done: 20, counts: [.coding: 20])
        let allOther = CloudImportMap(sampled: 60, done: 60, counts: [.other: 60])
        return offered(shares).map(\.category) == [.coding, .recipe, .music, .home, .style, .film]
            && TabSlots.encode(slots(for: [.coding, .home, .recipe])) == "today,code,cook,home,library"
            && slots(for: [.other]) == [.today, .library]
            && slots(for: [.coding, .home, .recipe, .music]).count == 5                   // a fourth pick is dropped
            && shouldShow(map: small, shaping: true, picked: false, eligible: true)
            && !shouldShow(map: settling, shaping: true, picked: false, eligible: true)
            && shouldShow(map: settled, shaping: true, picked: false, eligible: true)
            && !shouldShow(map: settled, shaping: true, picked: true, eligible: true)
            && !shouldShow(map: settled, shaping: false, picked: false, eligible: true)
            && !shouldShow(map: allOther, shaping: true, picked: false, eligible: true)
            && !shouldShow(map: nil, shaping: true, picked: false, eligible: true)
            // An import onto a library that already has saves is not the first import.
            && !shouldShow(map: settled, shaping: true, picked: false, eligible: false)
    }
    #endif
}
