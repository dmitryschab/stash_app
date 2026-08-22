// TabReselect.swift
//
// Tapping the tab you are already on returns that section to the top. UIKit's tab bar gives
// this away for free; the Stash bar is a custom pill (StashTabBar), so the gesture has to be
// wired by hand — the tap currently reaches a Button that assigns the tab it already holds.

import SwiftUI

/// A reselect signal. The count is the whole point: reselecting never changes `tab`, so
/// without it `onChange` would fire once and never again.
struct TabReselect: Equatable {
    var tab: StashTab = .today
    var count: Int = 0

    mutating func bump(_ tab: StashTab) {
        self = TabReselect(tab: tab, count: count + 1)
    }
}

private struct TabReselectKey: EnvironmentKey {
    static let defaultValue = TabReselect()
}

extension EnvironmentValues {
    var tabReselect: TabReselect {
        get { self[TabReselectKey.self] }
        set { self[TabReselectKey.self] = newValue }
    }
}

/// The id of a section's whole content; a `scrollTo` here is "the very top of the page". The
/// TimeRail uses it for its newest stop, so that one lands on the header, not on the first
/// month's label halfway down. (A module constant: `StashScrollView` is generic, and generic
/// types cannot hold a static.)
let stashSectionTopID = "stash.section.top"

/// A section's scroll view: `ScrollView`, plus the return-to-top on tab reselect.
///
/// ponytail: the whole content is the scroll anchor rather than a zero-height marker planted
/// above it — one `.id`, no extra layout container to perturb what each section already lays
/// out. Scrolling to a container with `.top` is the same thing as scrolling to its first row.
struct StashScrollView<Content: View>: View {
    let tab: StashTab
    @ViewBuilder var content: Content

    @Environment(\.tabReselect) private var reselect
    private let topID = stashSectionTopID

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content.id(topID)
            }
            .onChange(of: reselect) { _, signal in
                guard signal.tab == tab else { return }
                withAnimation(.easeOut(duration: 0.32)) {
                    proxy.scrollTo(topID, anchor: .top)
                }
            }
        }
    }
}
