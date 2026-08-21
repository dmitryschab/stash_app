// TikTokBrainApp.swift
//
// App entry point: registers the bundled Archivo faces, builds the SwiftData container,
// optionally seeds sample content (the simulator smoke run, or an App Review demo account —
// see SampleData.swift), and hosts the five-tab
// Set List shell (Today / Library / Cook / Music / Search) behind a custom ink pill tab bar.
// Mind map is deliberately not a tab — six slots crowded the pill, so it opens from the
// Library header instead, next to Import (it is a map of the library after all).
//
// The shell is gated on `StashSession`: signed out, RootView renders SignInView instead. The
// gate lives inside RootView and not around the Scene on purpose — `.modelContainer` and the
// scenePhase watcher must keep firing either way, so the auth guard belongs where the work is
// (PipelineCenter), not where the lifecycle is.

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
    case today, library, cook, music, search

    var label: String {
        switch self {
        case .today: "Today"
        case .library: "Library"
        case .cook: "Cook"
        case .music: "Music"
        case .search: "Search"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .library: "square.grid.2x2.fill"
        case .cook: "fork.knife"
        case .music: "music.note"
        case .search: "magnifyingglass"
        }
    }
}

struct RootView: View {
    // Simulator smoke runs can open a specific tab: `-initialTab library|cook|music|search`.
    @State private var tab: StashTab = {
        switch UserDefaults.standard.string(forKey: "initialTab") {
        case "library": .library
        case "cook": .cook
        case "music": .music
        case "search": .search
        default: .today
        }
    }()

    /// Bumped when the tab already on screen is tapped again; each section watches it.
    @State private var reselect = TabReselect()

    // Observes import progress so the sync pill shows on every tab, not just Import.
    private var center = PipelineCenter.shared
    private var session = StashSession.shared
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            switch session.state {
            case .unknown: splash
            case .signedOut: SignInView()
            case .signedIn: tabShell
            }
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .task { await session.restore() }
    }

    /// Shown for the moment it takes to read the Keychain — flashing the sign-in gate at an
    /// already-signed-in user on every cold launch would be worse than a blank beat.
    private var splash: some View {
        ProgressView()
            .tint(.stashInk)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tabShell: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .today: TodayView()
                case .library: LibraryView()
                case .cook: CookView()
                case .music: MusicView()
                case .search: SearchView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.tabReselect, reselect)

            VStack(spacing: 8) {
                if center.isImporting, let progress = center.progress, progress.total > 0 {
                    ImportSyncPill(done: progress.done, total: progress.total)
                }
                StashTabBar(selection: $tab, reselect: $reselect)
            }
        }
        // The scenePhase watcher already fired by the time sign-in completes, so kick the
        // pipeline here — this is the first moment there is an authenticated user to work for.
        .task(id: session.userID) {
            discardForeignLibrary()
            // App Review has no TikTok export to import, so a demo account brings its own
            // library. Runs after the wipe above, and only ever once per account.
            if session.isDemoAccount, let userID = session.userID {
                SampleData.seedDemoLibrary(into: context, userID: userID)
            }
            center.appBecameActive()
        }
    }

    /// SwiftData is one store per install, not one per account, so a second Apple ID signing in
    /// on the same device would open the previous user's library — their captions, transcripts
    /// and on-screen text. Drop it the first time a different `userID` appears.
    ///
    /// No recorded id means an install upgrading from build ≤13, which had no accounts at all:
    /// adopt the library rather than deleting what the owner already imported.
    private func discardForeignLibrary() {
        let key = "lastSignedInUserID"
        guard let userID = session.userID else { return }
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(userID, forKey: key)
        guard let previous, previous != userID else { return }
        try? context.delete(model: Video.self)
        try? context.save()
        try? FileManager.default.removeItem(at: ThumbnailStore.directory)
        try? FileManager.default.removeItem(at: AlbumStore.cacheURL)
        center.forgetCloudState()
    }
}

/// Slim status pill above the tab bar, shown on every tab while a local import is still
/// draining in the background — so leaving the Import screen never hides that it's running.
private struct ImportSyncPill: View {
    let done: Int
    let total: Int

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.mini)
                .tint(.stashOnInk)
            Micro(text: "Syncing \(done) of \(total)", size: 9.5, tracking: 0.9, color: .stashOnInk)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(Color.stashInk, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        .padding(.horizontal, 60)
    }
}

/// The solid ink pill: four equal slots, cream icons, uppercase micro labels.
struct StashTabBar: View {
    @Binding var selection: StashTab
    @Binding var reselect: TabReselect

    var body: some View {
        HStack(spacing: 0) {
            ForEach(StashTab.allCases, id: \.self) { tab in
                Button {
                    // Tapping the tab you are on is not a no-op: it means "take me back up".
                    if selection == tab { reselect.bump(tab) } else { selection = tab }
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

// `signInForPreview` is itself DEBUG-only, so in Release this body collapsed to a bare
// `return` inside a ViewBuilder and stopped the Release build compiling at all. Previews are
// a debug affordance; gate the whole thing rather than the one call inside it.
#if DEBUG
#Preview {
    StashSession.signInForPreview()
    return RootView()
        .modelContainer(SampleData.previewContainer)
}
#endif
