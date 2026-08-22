// TikTokBrainApp.swift
//
// App entry point: registers the bundled Archivo faces, builds the SwiftData container,
// optionally seeds sample content (the simulator smoke run, or an App Review demo account —
// see SampleData.swift), and hosts the five-tab
// Set List shell (Today / Code / Cook / Music / Library) behind a custom ink pill tab bar.
// Mind map is deliberately not a tab — six slots crowded the pill, so it opens from the
// Library header instead, next to Import (it is a map of the library after all). Search is
// not a tab either: hold the pill and push right, and the pill becomes the field (StashTabBar).
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
        assert(SearchGrip.selfTest(), "SearchGrip self-test failed")
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
    case today, code, cook, music, library

    var label: String {
        switch self {
        case .today: "Today"
        case .code: "Code"
        case .cook: "Cook"
        case .music: "Music"
        case .library: "Library"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .cook: "fork.knife"
        case .music: "music.note"
        case .library: "square.grid.2x2.fill"
        }
    }
}

struct RootView: View {
    // Simulator smoke runs can open a specific tab: `-initialTab code|cook|music|library`.
    @State private var tab: StashTab = {
        switch UserDefaults.standard.string(forKey: "initialTab") {
        case "code": .code
        case "cook": .cook
        case "music": .music
        case "library": .library
        default: .today
        }
    }()

    /// Bumped when the tab already on screen is tapped again; each section watches it.
    @State private var reselect = TabReselect()

    /// Search has no tab. The pill opens it (hold, push right — StashTabBar) and this is the
    /// open state; `-openSearch` lets a smoke run land in it.
    @State private var searchOpen = CommandLine.arguments.contains("-openSearch")
    @State private var query = ""
    /// Nobody finds hold-and-push on their own: a caption over the pill teaches it until the
    /// first time search opens.
    @AppStorage("searchGripHintDone") private var gripHintDone = false

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
                case .code: CodeView()
                case .cook: CookView()
                case .music: MusicView()
                case .library: LibraryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.tabReselect, reselect)

            // Over the tab, under the pill: the tab keeps its scroll position for when search closes.
            if searchOpen {
                SearchOverlay(query: $query)
                    .transition(.opacity)
            }

            VStack(spacing: 8) {
                if center.isImporting, let progress = center.progress, progress.total > 0 {
                    ImportSyncPill(done: progress.done, total: progress.total)
                }
                if !gripHintDone && !searchOpen {
                    Micro(text: "Hold the bar · push right to search", size: 9, tracking: 1.4, color: .stashInk.opacity(0.5))
                        .transition(.opacity)
                }
                StashTabBar(selection: $tab, reselect: $reselect, searchOpen: $searchOpen, query: $query)
            }
        }
        .animation(.easeOut(duration: 0.25), value: searchOpen)
        .onChange(of: searchOpen) { _, open in
            if open { gripHintDone = true }
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

/// The solid ink pill: five equal slots, cream icons, uppercase micro labels — and the search
/// field, once you hold it and push right. The pill *is* the field: the slots slide out the
/// right end while the magnifier and the text field slide in from the left, 1:1 with the
/// finger (`SearchGrip`). A tap is still a tap; the hold has to come first.
struct StashTabBar: View {
    @Binding var selection: StashTab
    @Binding var reselect: TabReselect
    @Binding var searchOpen: Bool
    @Binding var query: String

    /// 0 = tabs, 1 = field. Follows the finger while gripping.
    @State private var grip: CGFloat = 0
    @State private var held = false
    /// A slot's tap lands on the same touch-up that ends a grip, in whichever order SwiftUI
    /// likes; a grip that just ended is not a tab change.
    @State private var gripEndedAt = Date.distantPast
    @FocusState private var fieldFocused: Bool

    private var morph: CGFloat { searchOpen ? 1 : grip }

    var body: some View {
        ZStack {
            tabs
                .offset(x: morph * 64)
                .opacity(max(0, 1 - morph * 2))
                .allowsHitTesting(!searchOpen)
            field
                .offset(x: (1 - morph) * -30)
                .opacity(min(1, morph * 4))
                .allowsHitTesting(searchOpen)
        }
        .frame(height: 60)
        .background(Color.stashInk, in: Capsule())
        .clipShape(Capsule())
        .scaleEffect(held ? 1.03 : 1)
        .offset(y: held ? -3 : 0)
        .shadow(color: .black.opacity(held ? 0.4 : 0.28), radius: held ? 22 : 15, y: held ? 12 : 8)
        .simultaneousGesture(gripGesture, including: searchOpen ? .none : .all)
        .sensoryFeedback(.impact(weight: .medium), trigger: held) { _, now in now }
        .animation(.spring(duration: 0.35, bounce: 0.25), value: held)
        // VoiceOver and Switch Control users never need the gesture.
        .accessibilityAction(named: "Search") { open() }
        .onChange(of: searchOpen) { _, open in
            if open {
                fieldFocused = true
            } else {
                grip = 0
                query = ""
            }
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 4)
    }

    /// Slots are tap gestures, not Buttons: a Button fires on the touch-up that ends a push
    /// (its "still pressed" tolerance is wider than a slot), so every search open also switched
    /// tabs. A tap gesture is cancelled by the drag.
    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(StashTab.allCases, id: \.self) { tab in
                VStack(spacing: 3) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 17, weight: .semibold))
                    Micro(text: tab.label, size: 8.5, tracking: 0.7, color: color(for: tab))
                }
                .foregroundStyle(color(for: tab))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { select(tab) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(tab == selection ? [.isButton, .isSelected] : [.isButton])
            }
        }
        .opacity(held ? 0.3 : 1)
    }

    private func select(_ tab: StashTab) {
        guard !held, Date().timeIntervalSince(gripEndedAt) > 0.3 else { return }
        // Tapping the tab you are on is not a no-op: it means "take me back up".
        if selection == tab { reselect.bump(tab) } else { selection = tab }
    }

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.stashOnInk)
            TextField("", text: $query, prompt: Text("that bread video").foregroundColor(.stashOnInk.opacity(0.55)))
                .font(.archivo(15, .semibold))
                .foregroundStyle(Color.stashOnInk)
                .tint(.stashOnInk)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            Button { close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.stashOnInk)
                    .frame(width: 26, height: 26)
                    .background(Circle().strokeBorder(Color.stashOnInk.opacity(0.6), lineWidth: 1.5))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.leading, 22)
        .padding(.trailing, 8)
        // The way back mirrors the way in: a swipe left on the field hands the tabs back.
        .gesture(
            DragGesture(minimumDistance: 20).onEnded { value in
                if value.translation.width <= -60 { close() }
            }
        )
    }

    /// Hold, then push right. The long press has to succeed before the drag counts, and a
    /// release short of `SearchGrip.commitTravel` springs the pill back.
    private var gripGesture: some Gesture {
        LongPressGesture(minimumDuration: SearchGrip.holdDuration, maximumDistance: 30)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                held = true
                grip = SearchGrip.progress(dx: drag?.translation.width ?? 0)
            }
            .onEnded { value in
                held = false
                gripEndedAt = Date()
                if case .second(true, let drag) = value, SearchGrip.commits(dx: drag?.translation.width ?? 0) {
                    open()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { grip = 0 }
                }
            }
    }

    private func open() {
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
            grip = 1
            searchOpen = true
        }
    }

    private func close() {
        fieldFocused = false
        withAnimation(.spring(duration: 0.35, bounce: 0.15)) { searchOpen = false }
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
