// TikTokBrainApp.swift
//
// App entry point: registers the bundled Archivo faces, builds the SwiftData container,
// optionally seeds sample content (the simulator smoke run, or an App Review demo account —
// see SampleData.swift), and hosts the Set List shell (up to seven tabs, chosen in Settings)
// behind a custom ink pill tab bar. Five slots or fewer are all labelled; past five only the
// open one is, which is what lets seven fit where five labelled ones used to crowd. Mind map
// is deliberately not a tab — it opens from the Library header instead, next to Import (it is
// a map of the library after all). Search is not a tab either: a magnifier sits at the pill's
// right end, and holding the pill and pushing right is the accelerator (StashTabBar).
//
// The shell is gated on `StashSession`: signed out, RootView renders SignInView instead. The
// gate lives inside RootView and not around the Scene on purpose — `.modelContainer` and the
// scenePhase watcher must keep firing either way, so the auth guard belongs where the work is
// (PipelineCenter), not where the lifecycle is.

import SwiftUI
import SwiftData
import CoreText
import TikTokBrainKit
import TikTokOpenSDKCore

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
        assert(SearchIndex.selfTest(), "SearchIndex self-test failed")
        assert(TabSlots.selfTest(), "TabSlots self-test failed")
        assert(PipelineCenter.shellStatusSelfTest(), "PipelineCenter shell status self-test failed")
        assert(PipelineCenter.expectedSelfTest(), "PipelineCenter expected self-test failed")
        assert(PipelineCenter.firstSliceSelfTest(), "PipelineCenter first-slice self-test failed")
        assert(FocusPickerView.selfTest(), "FocusPickerView self-test failed")
        assert(SearchSuggestions.selfTest(), "SearchSuggestions self-test failed")
        assert(ImportView.selfTest(), "ImportView self-test failed")
        assert(MusicView.selfTest(), "MusicView self-test failed")
        assert(HaulDetailView.selfTest(), "HaulDetailView self-test failed")
        assert(CookedLog.selfTest(), "CookedLog self-test failed")
        assert(CookMatcher.selfTest(), "CookMatcher self-test failed")
        assert(FilmWall.selfTest(), "FilmWall self-test failed")
        #endif
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                // TikTok sign-in (Settings → TikTok) returns here from the TikTok app, through
                // the https redirect URI: SwiftUI hands a universal link over as a plain URL, so
                // no onContinueUserActivity is needed. The SDK's in-app browser never comes
                // through here — its ASWebAuthenticationSession catches the callback itself.
                .onOpenURL { url in _ = TikTokURLHandler.handleOpenURL(url) }
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

/// Every section that can hold a slot on the pill. `allCases` is the catalogue, in the order
/// Settings offers it and the order slots are drawn in; what is actually on screen is whatever
/// subset `TabSlots` holds.
enum StashTab: String, CaseIterable, Identifiable {
    // The four rich sections first, then every plain category in `librarySegments` order,
    // Library last. The order is the pill's and the Settings list's.
    case today, code, cook, music, films, haul
    case fitness, style, travel, home, learning, comedy, dining, wellness
    case library

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Lately"
        case .code: "Code"
        case .cook: "Cook"
        case .music: "Music"
        case .films: "Films"
        case .haul: "Haul"
        case .fitness: "Fitness"
        case .style: "Style"
        case .travel: "Travel"
        case .home: "Home"
        case .learning: "Learning"
        case .comedy: "Comedy"
        case .dining: "Dining"
        case .wellness: "Wellness"
        case .library: "Library"
        }
    }

    var symbol: String {
        switch self {
        case .today: "point.3.connected.trianglepath.dotted"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .cook: "fork.knife"
        case .music: "music.note"
        case .films: "movieclapper"
        case .haul: "bag.fill"
        case .library: "square.grid.2x2.fill"
        case .fitness, .style, .travel, .home, .learning, .comedy, .dining, .wellness:
            ownedCategory!.symbol
        }
    }

    /// One line for the Settings picker, so turning a section off is an informed choice.
    var blurb: String {
        switch self {
        case .today: "A few connections in your saves."
        case .code: "Coding saves, links first."
        case .cook: "Recipes as a photo wall."
        case .music: "Records and recommendation lists."
        case .films: "Every film your saves named, as a poster wall."
        case .haul: "Everything your saves are selling."
        case .fitness: "Workouts and training saves."
        case .style: "Outfits, beauty and hair."
        case .travel: "Places and trips."
        case .home: "Decor, cleaning and DIY."
        case .learning: "Facts, how-tos and explainers."
        case .comedy: "The ones that made you laugh."
        case .dining: "Restaurants, cafés and bars."
        case .wellness: "Health, sleep and habits."
        case .library: "Every shelf, plus Import and Settings."
        }
    }

    /// The category this tab shows on the app's behalf, if any. Library falls back on these
    /// when the tab is off (`libraryShelves(visible:)`); Today and Haul own nothing, because
    /// both are queries across every category rather than a home for one.
    var ownedCategory: Category? {
        switch self {
        case .cook: .recipe
        case .music: .music
        case .code: .coding
        case .films: .film
        case .fitness: .fitness
        case .style: .style
        case .travel: .travel
        case .home: .home
        case .learning: .learning
        case .comedy: .comedy
        case .dining: .dining
        case .wellness: .wellness
        case .today, .haul, .library: nil
        }
    }

    /// The tab that shows `category`, rich or plain; nil for `other`, which has no tab.
    static func tab(owning category: Category) -> StashTab? {
        allCases.first { $0.ownedCategory == category }
    }
}

/// Which sections the pill shows. Persisted as comma-joined `StashTab` raw values.
///
/// Two rules, both learned the hard way rather than chosen: Library can never be switched off,
/// because Import and Settings are only reachable from its header — a pill without it is a
/// configuration that cannot be undone from inside the app. And seven is the ceiling: past five
/// the labels go away and the slots are icon-only at ~37pt beside the open one, which is as
/// narrow as a slot can honestly go.
enum TabSlots {
    static let key = "tabSlots"
    static let maximum = 7
    /// Library last, and pinned: `decode` puts it back however the stored string was mangled.
    static let pinned: StashTab = .library
    static let fallback: [StashTab] = [.today, .code, .cook, .music, .library]

    static func decode(_ raw: String) -> [StashTab] {
        // Filtered through `allCases` rather than trusted in stored order: the pill's left-to-
        // right order is the catalogue's, duplicates collapse, and unknown names disappear.
        let stored = Set(raw.split(separator: ",").compactMap { StashTab(rawValue: String($0)) })
        guard !stored.isEmpty else { return fallback }
        var tabs = StashTab.allCases.filter(stored.contains)
        if !tabs.contains(pinned) { tabs.append(pinned) }
        // Trimming from the front would drop Today; the pinned tab has to survive either way.
        while tabs.count > maximum { tabs.removeFirst(where: { $0 != pinned }) }
        return tabs
    }

    static func encode(_ tabs: [StashTab]) -> String {
        StashTab.allCases.filter(tabs.contains).map(\.rawValue).joined(separator: ",")
    }

    /// Which slot sits under `x`, on a strip `stripWidth` wide holding `count` of them. The grip
    /// gesture needs this: it is attached to the whole pill, so when a hold turns out to have
    /// been a slow tap the only record of where the finger was is the drag's start point
    /// (`StashTabBar.gripGesture`). Nil past the strip — the pill's far end is the search
    /// button, and that is not a slot.
    ///
    /// The strip is only evenly divided while every slot is labelled. Past five, the open slot
    /// takes a fixed `openWidth` and the rest share what is left, so the arithmetic is two
    /// segments with a wide one wedged between them — dividing by an average width instead
    /// lands one slot off for every touch to the left of the open one.
    ///
    /// `openWidth` nil (or an `openIndex` that is not on the pill) means the even strip.
    static func slotIndex(x: CGFloat, stripWidth: CGFloat, count: Int,
                          openIndex: Int?, openWidth: CGFloat?) -> Int? {
        guard count > 0, stripWidth > 0, x < stripWidth else { return nil }
        let touch = max(0, x)
        guard let openWidth, let openIndex, count > 1,
              openIndex >= 0, openIndex < count, openWidth < stripWidth else {
            return min(count - 1, Int(touch / (stripWidth / CGFloat(count))))
        }
        let narrow = (stripWidth - openWidth) / CGFloat(count - 1)
        let openStart = narrow * CGFloat(openIndex)
        if touch < openStart { return min(openIndex - 1, Int(touch / narrow)) }
        if touch < openStart + openWidth { return openIndex }
        return min(count - 1, openIndex + 1 + Int((touch - openStart - openWidth) / narrow))
    }

    #if DEBUG
    /// Two things that are invisible from any single call site: the set arithmetic above, which
    /// decides whether the user can reach Settings at all, and the slot geometry, which decides
    /// which tab a slow tap lands on. Both get checked on every debug launch.
    static func selfTest() -> Bool {
        // Five slots or fewer: all labelled, all the same width.
        slotIndex(x: 0, stripWidth: 300, count: 5, openIndex: 2, openWidth: nil) == 0
            && slotIndex(x: 59, stripWidth: 300, count: 5, openIndex: 2, openWidth: nil) == 0
            && slotIndex(x: 60, stripWidth: 300, count: 5, openIndex: 2, openWidth: nil) == 1
            && slotIndex(x: 299, stripWidth: 300, count: 5, openIndex: 2, openWidth: nil) == 4
            // touch slop off the left edge is still the first slot
            && slotIndex(x: -3, stripWidth: 300, count: 5, openIndex: 2, openWidth: nil) == 0
            // the search button's end
            && slotIndex(x: 310, stripWidth: 300, count: 5, openIndex: 2, openWidth: nil) == nil
            // before the first layout pass
            && slotIndex(x: 10, stripWidth: 0, count: 5, openIndex: 2, openWidth: nil) == nil
            && slotIndex(x: 10, stripWidth: 300, count: 0, openIndex: 0, openWidth: nil) == nil
            // Seven slots on a 393pt phone: six 37pt slots, then Library open at 64pt.
            && slotIndex(x: 0, stripWidth: 286, count: 7, openIndex: 6, openWidth: 64) == 0
            && slotIndex(x: 200, stripWidth: 286, count: 7, openIndex: 6, openWidth: 64) == 5
            && slotIndex(x: 221, stripWidth: 286, count: 7, openIndex: 6, openWidth: 64) == 5
            && slotIndex(x: 230, stripWidth: 286, count: 7, openIndex: 6, openWidth: 64) == 6
            && slotIndex(x: 285, stripWidth: 286, count: 7, openIndex: 6, openWidth: 64) == 6
            // Six slots with the open one in the middle: 41.2pt either side of an 80pt wedge.
            && slotIndex(x: 10, stripWidth: 286, count: 6, openIndex: 2, openWidth: 80) == 0
            && slotIndex(x: 50, stripWidth: 286, count: 6, openIndex: 2, openWidth: 80) == 1
            && slotIndex(x: 100, stripWidth: 286, count: 6, openIndex: 2, openWidth: 80) == 2  // inside the wedge
            && slotIndex(x: 161, stripWidth: 286, count: 6, openIndex: 2, openWidth: 80) == 2
            && slotIndex(x: 200, stripWidth: 286, count: 6, openIndex: 2, openWidth: 80) == 3
            && slotIndex(x: 285, stripWidth: 286, count: 6, openIndex: 2, openWidth: 80) == 5
            // An open tab that is no longer on the pill falls back on the even strip.
            && slotIndex(x: 200, stripWidth: 286, count: 7, openIndex: nil, openWidth: 64) == 4
            && decode("") == fallback
            && decode("garbage") == fallback
            && decode("cook") == [.cook, .library]
            && decode("library") == [.library]
            && decode("music,cook") == [.cook, .music, .library]        // catalogue order, not stored order
            && decode("cook,cook,cook") == [.cook, .library]            // duplicates collapse
            && decode("today,code,cook,music,haul") == [.today, .code, .cook, .music, .haul, .library]
            && encode([.haul, .today]) == "today,haul"
            && librarySegments.filter { $0 != .other }.allSatisfy { StashTab.tab(owning: $0) != nil }
            && StashTab.tab(owning: .other) == nil
            && StashTab.tab(owning: .recipe) == .cook && StashTab.tab(owning: .home) == .home
            && decode("home,style") == [.style, .home, .library]                   // catalogue order
            && decode("today,code,cook,music,films,haul,home,style,wellness")       // nine asked for
                == [.music, .films, .haul, .style, .home, .wellness, .library]        // seven kept, Library pinned
            && decode(encode([.today, .haul, .library])) == [.today, .haul, .library]
    }
    #endif
}

private extension Array {
    /// Removes the first element matching `predicate`, if any.
    mutating func removeFirst(where predicate: (Element) -> Bool) {
        guard let index = firstIndex(where: predicate) else { return }
        remove(at: index)
    }
}

struct RootView: View {
    // Simulator smoke runs can open a specific tab: `-initialTab code|cook|music|films|haul|library`.
    @State private var tab: StashTab = UserDefaults.standard.string(forKey: "initialTab")
        .flatMap(StashTab.init(rawValue:)) ?? .today

    /// Which sections are on the pill, chosen in Settings. Read here rather than inside
    /// `StashTabBar` because the shell needs it too: a tab switched off while it is on screen
    /// has to hand the user somewhere, and Library needs to know which shelves to take back.
    @AppStorage(TabSlots.key) private var slotsRaw = TabSlots.encode(TabSlots.fallback)
    private var slots: [StashTab] { TabSlots.decode(slotsRaw) }

    /// Bumped when the tab already on screen is tapped again; each section watches it.
    @State private var reselect = TabReselect()

    /// Search has no tab. The pill's magnifier opens it — as does hold-and-push, for the people
    /// who learn it (StashTabBar) — and this is the open state; `-openSearch` lets a smoke run
    /// land in it.
    @State private var searchOpen = CommandLine.arguments.contains("-openSearch")
    @State private var query = ""
    @State private var tabBarHidden = false
    /// The splash has been up long enough that it is no longer a beat; see `splash`.
    @State private var splashStalled = false
    /// Set when the welcome is dismissed. Separate from the UserDefaults flag `needsWelcome`
    /// reads, because a plain `UserDefaults.set` does not invalidate a SwiftUI body — without
    /// this the screen would still be there after Continue.
    @State private var welcomeDismissed = false

    /// The focus picker, once per account. The key is set on every way out — picked, skipped
    /// or swiped away — so it is seen once and Settings is where tabs change after that.
    @State private var focusPickerShown = false
    private static func focusKey(_ userID: String) -> String { "focusPicked-\(userID)" }
    private var focusPicked: Bool {
        guard let userID = session.userID else { return true }
        return UserDefaults.standard.bool(forKey: Self.focusKey(userID))
    }
    private func markFocusPicked() {
        if let userID = session.userID { UserDefaults.standard.set(true, forKey: Self.focusKey(userID)) }
    }

    /// Presents the picker when every condition holds. Nothing is presented over Import or
    /// Settings, and nothing for a demo account or an import that is not the account's first.
    private func considerFocusPicker() {
        guard !focusPickerShown, !center.screenBusy, !center.importRouteRequested, !session.isDemoAccount else { return }
        #if DEBUG
        if Self.forcesFocusPicker { focusPickerShown = true; return }
        #endif
        if FocusPickerView.shouldShow(map: center.cloudStatus?.map, shaping: center.isShapingLibrary,
                                      picked: focusPicked,
                                      eligible: center.cloudStatus?.importID == center.focusEligibleImportID) {
            focusPickerShown = true
        }
    }
    #if DEBUG
    /// `-showFocusPicker` presents the sheet over a seeded library with sample shares — the
    /// only way to screenshot it without an import.
    private static var forcesFocusPicker: Bool { CommandLine.arguments.contains("-showFocusPicker") }
    private static let sampleShares: [(category: Category, count: Int)] =
        [(.coding, 230), (.recipe, 180), (.music, 90), (.home, 60), (.film, 40), (.style, 25)]
    #endif

    // Observes import progress so the sync pill shows on every tab, not just Import.
    private var center = PipelineCenter.shared
    private var session = StashSession.shared
    private var subscription = Subscription.shared
    @Environment(\.modelContext) private var context

    var body: some View {
        Group {
            if Self.forcesPaywall {
                PaywallView()
            } else {
                switch session.state {
                case .unknown: splash
                case .signedOut: SignInView()
                case .signedIn: paidShell
                }
            }
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .task { await session.restore() }
    }

    /// The second gate. Signed in is not the same as paid for since 1.1: the app is free to
    /// download and a €2.99/month subscription is what opens it — after the first fifty
    /// videos, which are free and are what `session.isOnTrial` is reading.
    ///
    /// The trial is deliberately *not* folded into `isEntitled`. Nobody paid, and an app that
    /// says "subscribed" to a trial user has to un-say it later; Settings shows a counter
    /// instead, and this gate is the only place the two are treated alike.
    ///
    /// The splash in the last branch matters more than it looks. `isEntitled` restores from
    /// the Keychain, so a subscriber usually lands straight on `tabShell` — but a reinstall
    /// has no cached answer, and showing a checkout to somebody who already pays, for the
    /// second it takes StoreKit and /v1/me to reply, is the worst frame this app could draw.
    /// `quota == nil` is that same unknown for a trial user, so it waits too.
    private var paidShell: some View {
        Group {
            if session.isEntitled || session.isOnTrial {
                if welcomeDismissed || !needsWelcome {
                    tabShell
                } else {
                    WelcomeView {
                        if let userID = session.userID {
                            UserDefaults.standard.set(true, forKey: Self.welcomeKey(userID))
                        }
                        withAnimation(.easeOut(duration: 0.25)) { welcomeDismissed = true }
                    }
                }
            } else if subscription.hasSynced && session.quota != nil {
                PaywallView()
            } else {
                splash
            }
        }
        .task { subscription.start() }
        // `quota == nil` is one of the two things the last branch waits for, and nothing else
        // on this path asks for it: a restored session that came back without a quota would
        // sit on the splash until something unrelated happened to fetch one.
        .task { if session.quota == nil { await session.refreshQuota() } }
    }

    /// `-showPaywall` renders the checkout with no account and no receipt — the only way to
    /// screenshot it or eyeball it in the simulator, where there is neither. It sits above the
    /// sign-in switch, not inside `paidShell`, because reaching `paidShell` needs the very
    /// account this flag exists to do without. DEBUG-only: a Release build has no path to the
    /// paywall except by genuinely not having paid.
    #if DEBUG
    private static var forcesPaywall: Bool { CommandLine.arguments.contains("-showPaywall") }
    #else
    private static let forcesPaywall = false
    #endif

    /// Shown for the moment it takes to read the Keychain — flashing the sign-in gate at an
    /// already-signed-in user on every cold launch would be worse than a blank beat.
    ///
    /// A beat is all it is meant to be. Eight seconds in it is not a beat any more, it is the
    /// one screen in the app with no way out, so it says what it is waiting for and offers the
    /// only move there is.
    private var splash: some View {
        VStack(spacing: StashSpacing.group) {
            ProgressView()
                .tint(.stashInk)
            if splashStalled {
                VStack(spacing: StashSpacing.item) {
                    Micro(text: "Still checking your account…", size: 10, tracking: 1.4)
                    StashPrimaryButton(title: "Try again") {
                        Task { await session.refreshQuota() }
                    }
                }
                .padding(.horizontal, 24)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            splashStalled = false   // a splash shown again (sign-out, sign-in) gets its own beat
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { splashStalled = true }
        }
    }

    /// Shown once, the first time an account reaches the shell: what the fifty free videos
    /// are, and what happens after them. Keyed on the account rather than the install so a
    /// second Apple ID on the same phone gets its own — and so a reinstall of an account
    /// that has already seen it does not sit through it twice.
    private static func welcomeKey(_ userID: String) -> String { "welcomed-\(userID)" }

    private var needsWelcome: Bool {
        guard let userID = session.userID else { return false }
        // A demo account skips it: App Review is handed a seeded library and a working
        // subscription page, and a trial screen in front of both is a screen about an offer
        // that does not apply to them.
        guard !session.isDemoAccount else { return false }
        #if DEBUG
        // A seeded smoke run has an invented account and no server, so every screenshot pass
        // would otherwise start behind this. `-showWelcome` is how it gets captured on purpose.
        if CommandLine.arguments.contains("-seedSample") || CommandLine.arguments.contains("-seedFile")
            || CommandLine.arguments.contains("-seedLately") {
            return CommandLine.arguments.contains("-showWelcome")
        }
        #endif
        return !UserDefaults.standard.bool(forKey: Self.welcomeKey(userID))
    }

    private var tabShell: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch tab {
                case .today: LatelyView()
                case .code: CodeView()
                case .cook: CookView()
                case .music: MusicView()
                case .films: FilmsView()
                case .haul: HaulView()
                case .fitness, .style, .travel, .home, .learning, .comedy, .dining, .wellness:
                    CategoryView(tab: tab)
                case .library: LibraryView(shelves: libraryShelves(visible: slots),
                                           includeBuyShelf: !slots.contains(.haul))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.tabReselect, reselect)
            .environment(\.stashTabBarHidden, $tabBarHidden)

            // Over the tab, under the pill: the tab keeps its scroll position for when search closes.
            if searchOpen {
                SearchOverlay(query: $query)
                    .transition(.opacity)
            }

            if !tabBarHidden {
            VStack(spacing: 8) {
                // One channel for the whole pipeline: which of these is showing, and in what
                // order they beat each other, is `PipelineCenter.shellStatus`'s decision — a
                // failed share carries its own words, so the pill never claims "Syncing" over
                // a share that already died.
                if let status = center.shellStatus {
                    ImportSyncPill(status: status) {
                        // Search is an overlay over the tab, so routing under it would push
                        // Import behind the results and look like nothing happened.
                        searchOpen = false
                        tab = .library
                        center.importRouteRequested = true
                    } dismiss: {
                        center.dismissShellStatus()
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                StashTabBar(slots: slots, selection: $tab, reselect: $reselect,
                            searchOpen: $searchOpen, query: $query)
            }
            }
        }
        // Switching a section off in Settings while standing on it would otherwise leave the
        // shell rendering a tab no slot points at, with no way back but a relaunch.
        .onChange(of: slotsRaw) { _, _ in
            if !slots.contains(tab) { tab = slots.first ?? .library }
        }
        // Every signal that can complete the picker's conditions: the map settling, Import or
        // Settings closing, the pill's route to Import finishing. The map usually settles while
        // the user is on Import watching it, so the close is the trigger that matters most.
        .onChange(of: center.cloudStatus?.map?.done, initial: true) { _, _ in considerFocusPicker() }
        .onChange(of: center.screenBusy) { _, _ in considerFocusPicker() }
        .onChange(of: center.importRouteRequested) { _, _ in considerFocusPicker() }
        .sheet(isPresented: $focusPickerShown, onDismiss: markFocusPicked) {
            #if DEBUG
            let shares = Self.forcesFocusPicker ? Self.sampleShares : center.mapShares
            #else
            let shares = center.mapShares
            #endif
            FocusPickerView(shares: shares) { picks in
                if !picks.isEmpty { slotsRaw = TabSlots.encode(FocusPickerView.slots(for: picks)) }
                focusPickerShown = false
            }
            .presentationDetents([.large])
        }
        .animation(.easeOut(duration: 0.25), value: searchOpen)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: center.shellStatus)
        // The scenePhase watcher already fired by the time sign-in completes, so kick the
        // pipeline here — this is the first moment there is an authenticated user to work for.
        .task(id: session.userID) {
            discardForeignLibrary()
            // After the wipe, never before: adopting first would hydrate the incoming account
            // from a file the line above is about to delete, and a digest describes saves.
            LatelyStore.shared.adopt(userID: session.userID)
            // App Review has no TikTok export to import, so a demo account brings its own
            // library. Runs after the wipe above, and only ever once per account.
            if session.isDemoAccount, let userID = session.userID {
                SampleData.seedDemoLibrary(into: context, userID: userID)
            }
            // Before the pipeline wakes: an empty library comes back from the account first.
            await center.restoreLibraryIfEmpty()
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
        // The digest is a description of the outgoing library, so it goes with it.
        LatelyStore.discardState(for: previous)
        LocalImageCache.shared.removeAll()
        try? FileManager.default.removeItem(at: ThumbnailStore.directory)
        try? FileManager.default.removeItem(at: AlbumStore.cacheURL)
        try? FileManager.default.removeItem(at: OfferStore.cacheURL)
        DeliveryAddress.forget()
        center.forgetCloudState()
    }
}

/// Slim status pill above the tab bar, shown on every tab for whatever the pipeline is doing —
/// reading an export, syncing, a shared TikTok in flight, a finished import, or the error that
/// stopped one — so no screen ever hides that it is running, or that it stopped.
///
/// It is a button: the detail lives on Import, and a status you cannot follow up on is half a
/// status. The ones that will not clear themselves (`finished`, `failed`) carry an ✕.
private struct ImportSyncPill: View {
    let status: PipelineCenter.ShellStatus
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: open) {
                HStack(spacing: 9) {
                    leading
                    Micro(text: text, size: 9.5, tracking: 0.9, color: .stashOnInk)
                        .lineLimit(1)
                        // "TRANSCRIPTS 959 OF 959" fits with ~7 pt to spare on a 393 pt phone; a
                        // four-digit library would not, so it gives a little before it truncates.
                        .minimumScaleFactor(0.85)
                    if case .syncing(let done, let total) = status {
                        track(done: done, total: total)
                    } else if case .readingLibrary(_, let done, let total) = status {
                        track(done: done, total: total)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, isDismissible ? 2 : 16)
                // A thumb around a 34pt look: `minTapTarget` would grow the capsule itself,
                // and the pill is meant to stay a hairline over the tab bar.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text)
            .accessibilityHint("Opens Import")

            if isDismissible {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.stashOnInk.opacity(0.75))
                        .minTapTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .background {
            Capsule()
                .fill(Color.stashInk)
                .frame(height: 34)
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
        }
        .padding(.horizontal, 60)
    }

    private var text: String {
        switch status {
        case .reading: "Reading your export…"
        case .syncing(let done, let total): "Syncing \(done) of \(total)"
        case .readingLibrary(let what, let done, let total): "\(what) \(done) of \(total)"
        // A shared TikTok has no done/total — the pill just says one is in flight.
        case .shares(let count): count == 1 ? "Syncing 1 share" : "Syncing \(count) shares"
        case .finished(let sorted): "\(sorted) videos sorted"
        case .failed(let message): message
        }
    }

    /// Spinner for work still moving, a mark for the two that have stopped.
    @ViewBuilder private var leading: some View {
        switch status {
        case .reading, .syncing, .readingLibrary, .shares:
            ProgressView()
                .controlSize(.mini)
                .tint(.stashOnInk)
        case .finished:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.stashOnInk)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.stashOnInk)
        }
    }

    /// The count says how far along; the track says how far there is to go.
    private func track(done: Int, total: Int) -> some View {
        let fraction = total > 0 ? min(1, max(0, Double(done) / Double(total))) : 0
        return Capsule()
            .fill(Color.stashOnInk.opacity(0.25))
            .frame(width: 48, height: 3)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.stashOnInk)
                    .frame(width: 48 * fraction, height: 3)
            }
    }

    /// Nothing else will clear these two: a finished import and an error both sit there until
    /// they are waved away (`PipelineCenter.dismissShellStatus`).
    private var isDismissible: Bool {
        switch status {
        case .finished, .failed: true
        case .reading, .syncing, .readingLibrary, .shares: false
        }
    }
}

/// The solid ink pill: up to seven slots, cream icons, uppercase micro labels, and a magnifier
/// at the right end — and the search field, once you hold the pill and push right. The pill
/// *is* the field: the slots slide out the right end while the magnifier and the text field
/// slide in from the left, 1:1 with the finger (`SearchGrip`). The gesture is the accelerator,
/// not the entrance; the button at the end is the entrance. A tap is still a tap, and since
/// the grip owns the touch, a hold that never moved is one too.
struct StashTabBar: View {
    /// Which sections have a slot, left to right. Chosen in Settings (`TabSlots`).
    var slots: [StashTab] = TabSlots.fallback
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
    /// …unless the grip never moved, which is a slow tap and *is* a tab change. Then both the
    /// release and the slot's own tap gesture ask for the same selection, and whichever arrives
    /// second is dropped — it would otherwise read as "tapped the tab you are on" and bump.
    @State private var selectedAt = Date.distantPast
    /// How wide the slots actually are, which is no longer the pill: the search button takes
    /// the right end. Read by the grip's release (`TabSlots.slotIndex`).
    @State private var slotStripWidth: CGFloat = 0
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
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    /// Slots are tap gestures, not Buttons: a Button fires on the touch-up that ends a push
    /// (its "still pressed" tolerance is wider than a slot), so every search open also switched
    /// tabs. A tap gesture is cancelled by the drag.
    ///
    /// Five slots or fewer are all labelled and split the strip evenly — `point.3.connected`
    /// and a grid of squares are not words, and a bar the user has to decode is not a bar.
    /// Past five there is no room for six or seven labels, so only the open slot keeps one and
    /// widens to hold it; at seven that widening has to come down to 64pt or the icon-only
    /// slots drop under a thumb.
    private var tabs: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(slots) { tab in
                    let open = tab == selection
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 17, weight: .semibold))
                        if labelsAlwaysOn || open {
                            Micro(text: tab.label, size: 8.5, tracking: 0.7, color: labelColor(for: tab))
                                .lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    .foregroundStyle(color(for: tab))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(width: open ? openSlotWidth : nil)
                    .background {
                        if open {
                            Capsule().fill(Color.stashOnInk.opacity(0.12)).padding(.vertical, 6)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { select(tab) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(tab.label)
                    .accessibilityAddTraits(open ? [.isButton, .isSelected] : [.isButton])
                }
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { slotStripWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in slotStripWidth = width }
                }
            }

            Rectangle()
                .fill(Color.stashOnInk.opacity(0.18))
                .frame(width: 1, height: 28)
                .padding(.horizontal, 8)

            // The entrance to search, as plain as Cook's and Haul's fields: hold-and-push is
            // faster once you know it, and nobody knows it on the first launch.
            Button { open() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.stashOnInk)
                    .frame(width: 44, height: 44)
                    .background(Circle().strokeBorder(Color.stashOnInk.opacity(0.4), lineWidth: 1.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search")
            .padding(.trailing, 6)
        }
        .animation(.spring(duration: 0.3, bounce: 0.2), value: selection)
        .opacity(held ? 0.3 : 1)
    }

    /// Whether every slot carries its label, or only the open one (see `tabs`).
    private var labelsAlwaysOn: Bool { slots.count <= 5 }

    /// How wide the open slot is when it is the only labelled one. Nil while all of them are:
    /// then they share the strip evenly and nothing is special about the one you are on.
    private var openSlotWidth: CGFloat? {
        guard !labelsAlwaysOn else { return nil }
        return slots.count == 7 ? 64 : 80
    }

    private func select(_ tab: StashTab) {
        guard !held, Date().timeIntervalSince(gripEndedAt) > 0.3 else { return }
        choose(tab)
    }

    /// One selection per touch-up, whichever gesture reports it first (see `selectedAt`).
    private func choose(_ tab: StashTab) {
        guard Date().timeIntervalSince(selectedAt) > 0.2 else { return }
        selectedAt = Date()
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
    ///
    /// A release that never travelled is the third case, and the one that used to be a dead
    /// end: the grip takes the touch from the slot the moment the hold succeeds, so a finger
    /// that rests for four tenths of a second and lifts fired the haptic, dimmed the bar and
    /// then did nothing at all. A slow tap is a tap — the slot it started over is the slot.
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
                guard case .second(true, let drag) = value else {
                    gripEndedAt = Date()
                    withAnimation(.spring(duration: 0.35, bounce: 0.3)) { grip = 0 }
                    return
                }
                let translation = drag?.translation ?? .zero
                if SearchGrip.commits(dx: translation.width) {
                    gripEndedAt = Date()
                    open()
                    return
                }
                withAnimation(.spring(duration: 0.35, bounce: 0.3)) { grip = 0 }
                if hypot(translation.width, translation.height) < Self.tapTravel,
                   let index = TabSlots.slotIndex(x: drag?.startLocation.x ?? 0,
                                                  stripWidth: slotStripWidth, count: slots.count,
                                                  openIndex: slots.firstIndex(of: selection),
                                                  openWidth: openSlotWidth) {
                    // No swallow: this touch-up meant something, and the slot's own tap gesture
                    // reporting it too is handled by `choose`.
                    choose(slots[index])
                } else {
                    gripEndedAt = Date()
                }
            }
    }

    /// How far a release may have travelled and still count as a tap rather than an abandoned
    /// push. Roughly a finger's roll on the glass.
    private static let tapTravel: CGFloat = 10

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

    /// Labels do not dim as far as their glyphs. A shape at 45% still reads as a shape; 8.5pt
    /// type at 45% is the smallest thing in the app and would fall under the floor the design
    /// sets for it.
    private func labelColor(for tab: StashTab) -> Color {
        tab == selection ? .stashOnInk : .stashOnInk.opacity(0.62)
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
