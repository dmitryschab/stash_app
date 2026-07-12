// TikTokBrainApp.swift
//
// App entry point: registers the bundled Archivo faces, builds the SwiftData container,
// optionally seeds sample content for the simulator smoke run, and hosts the four-tab
// Set List shell (Today / Library / Search / Mind map) behind a custom ink pill tab bar.

import SwiftUI
import SwiftData
import CoreText
import TikTokBrainKit

@main
struct TikTokBrainApp: App {
    let container: ModelContainer

    init() {
        // Archivo ships as bundled TTFs; runtime registration avoids Info.plist font keys.
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        do {
            container = try ModelContainer(for: Video.self)
        } catch {
            fatalError("Could not create the SwiftData container: \(error)")
        }
        SampleData.seedIfRequested(container)
        // Background continuation: register before launch completes, then hand the
        // center its container so resume works without any screen being open.
        PipelineCenter.registerBackgroundTask()
        PipelineCenter.shared.configure(container: container)
        #if DEBUG
        assert(MindMapEngine.selfTest(), "MindMapEngine self-test failed")
        #endif
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: PipelineCenter.shared.appBecameActive()
            case .background: PipelineCenter.shared.appEnteredBackground()
            default: break
            }
        }
    }
}

// MARK: - Tab shell

enum StashTab: CaseIterable {
    case today, library, search, mindMap

    var label: String {
        switch self {
        case .today: "Today"
        case .library: "Library"
        case .search: "Search"
        case .mindMap: "Mind map"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .library: "square.grid.2x2.fill"
        case .search: "magnifyingglass"
        case .mindMap: "circle.hexagongrid.fill"
        }
    }
}

struct RootView: View {
    // Simulator smoke runs can open a specific tab: `-initialTab library|search|mindmap`.
    @State private var tab: StashTab = {
        switch UserDefaults.standard.string(forKey: "initialTab") {
        case "library": .library
        case "search": .search
        case "mindmap": .mindMap
        default: .today
        }
    }()

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .today: TodayView()
                case .library: LibraryView()
                case .search: SearchView()
                case .mindMap: MindMapView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            StashTabBar(selection: $tab)
        }
        .background(Color.stashBackground.ignoresSafeArea())
    }
}

/// The solid ink pill: four equal slots, cream icons, uppercase micro labels.
struct StashTabBar: View {
    @Binding var selection: StashTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StashTab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .semibold))
                        Micro(text: tab.label, size: 8.5, tracking: 0.7, color: color(for: tab))
                    }
                    .foregroundStyle(color(for: tab))
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
            }
        }
        .frame(height: 60)
        .background(Color.stashInk, in: Capsule())
        .shadow(color: .black.opacity(0.28), radius: 15, y: 8)
        .padding(.horizontal, 34)
        .padding(.bottom, 4)
    }

    private func color(for tab: StashTab) -> Color {
        tab == selection ? .stashOnInk : .stashOnInk.opacity(0.45)
    }
}

/// Bottom clearance so scroll content is not hidden behind the floating tab bar.
let stashTabBarClearance: CGFloat = 96

#Preview {
    RootView()
        .modelContainer(SampleData.previewContainer)
}
