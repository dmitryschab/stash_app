// ImportView.swift
//
// The Import screen (pushed from Library), which doubles as pipeline status/history. It
// imports an extracted TikTok export (JSON file or folder), runs the pipeline via
// `PipelineRunner`, shows live progress and model-box reachability, and hosts the
// box-config settings sheet. Set List style: sync card, outlined status card, count grid.
//
// This is the screen where a library leaves the phone, so it is also where the third-party
// processing is disclosed — named providers, in the card directly above the submit button.
// The `ConnectFlowView` mockup is reachable from here in DEBUG only; see `connectPrototype`.

import SwiftUI
import SwiftData
import Observation
import UniformTypeIdentifiers
import TikTokBrainKit

// MARK: - Box status

enum BoxStatus {
    case unknown, checking, online, offline

    var label: String {
        switch self {
        case .unknown: "Not checked"
        case .checking: "Checking…"
        case .online: "Online"
        case .offline: "Unreachable"
        }
    }

    var color: Color {
        switch self {
        case .unknown: .stashInk.opacity(0.45)
        case .checking: .categoryMusic
        case .online: .categoryCoding
        case .offline: .categoryOther
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "questionmark.circle"
        case .checking: "arrow.triangle.2.circlepath"
        case .online: "checkmark.circle.fill"
        case .offline: "wifi.exclamationmark"
        }
    }
}

// MARK: - Box config storage

/// Default box configuration: the cloud pipeline API. There is no compiled-in bearer any
/// more — every /v1 call carries the signed-in user's JWT from `StashSession` — but debug
/// builds can still point the base URL at a local box. Debug only: that field decides where
/// the session tokens are posted.
enum BoxDefaults {
    static let baseURL = "https://stash.dmitrijs.dev/v1"
    static let chatModel = "google.gemma-4-26b-a4b"   // pinned server-side; informational
    static let whisperModel = "whisper-large-v3-turbo" // pinned server-side; informational
}

func makeBoxConfig(baseURL: String, chatModel: String, whisperModel: String,
                   auth: StashAuthProvider = StashSession.authProvider) -> BoxConfig {
    BoxConfig(
        baseURL: URL(string: baseURL) ?? URL(string: "http://localhost:9")!,
        chatModel: chatModel,
        whisperModel: whisperModel,
        auth: auth
    )
}

// MARK: - View

struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Query private var videos: [Video]
    private var controller = PipelineCenter.shared
    private var session = StashSession.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showGuide = false
    #if DEBUG
    @State private var showConnect = false
    #endif

    private var usesCloudImport: Bool { PipelineCenter.cloudImportEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                syncCard.padding(.top, 16)
                if let quota = session.quota { quotaCard(quota).padding(.top, 12) }
                importSection.padding(.top, 12)
                if !usesCloudImport {
                    boxCard.padding(.top, 12)
                }
                #if DEBUG
                connectPrototype.padding(.top, 12)
                #endif
                if let error = controller.lastError {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 13, weight: .bold))
                        Text(error).font(.archivo(13, .semibold))
                    }
                    .foregroundStyle(Color.categoryRecipe)
                    .padding(.top, 14)
                }
                librarySection.padding(.top, 24)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, stashTabBarClearance)
        }
        .background(Color.stashBackground.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json, .folder],
            allowsMultipleSelection: false
        ) { handleImport($0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showGuide) { DataDownloadGuideView() }
        .task {
            // The counter on this screen is the one the user reads before spending, so make it
            // authoritative rather than however fresh the last foreground left it.
            await session.refreshQuota()
            if usesCloudImport {
                controller.syncCloudImportIfNeeded()
            } else {
                await controller.pingBox()
            }
        }
    }

    // MARK: - Sections

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StashBackButton()
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.stashInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            Text("Import")
                .font(.archivo(40, .heavy))
                .foregroundStyle(Color.stashInk)
                .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    /// The headline card: live sync state with the progress bar, and the screen's biggest tap
    /// target. It opens the file importer — the only thing this screen can actually do. It used
    /// to open `ConnectFlowView`, the OAuth mockup, which made the most prominent control on the
    /// screen a promise the app cannot keep (guideline 2.2).
    private var syncCard: some View {
        Button { showImporter = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Micro(text: "TikTok", size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7))
                    Spacer()
                    Micro(
                        text: usesCloudImport ? "Cloud import" : (controller.isImporting ? "Syncing" : "On this iPhone"),
                        size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7)
                    )
                }
                Text(usesCloudImport ? "Cloud import" : (controller.isImporting ? "Syncing favorites" : "Import your saves"))
                    .font(.archivo(23, .heavy))
                    .foregroundStyle(Color.stashOnAccent)
                    .padding(.top, 9)
                Text(subtitleLine)
                    .font(.archivo(13, .semibold))
                    .foregroundStyle(Color.stashOnAccent.opacity(0.8))
                    .padding(.top, 4)
                if let progress = localProgress, progress.total > 0 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.stashOnAccent.opacity(0.25))
                            Capsule().fill(Color.stashOnAccent)
                                .frame(width: geo.size.width * CGFloat(progress.done) / CGFloat(progress.total))
                        }
                    }
                    .frame(height: 8)
                    .padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .stashCard(fill: .categoryCoding)
        }
        .buttonStyle(.plain)
        // Both import paths already `guard !isImporting`, so a tap mid-run would be a dead one.
        // Deliberately without the `.opacity` dim the primary button pairs with its `.disabled`:
        // this card is also the progress readout, and fading the bar as it fills reads backwards.
        .disabled(controller.isImporting)
    }

    #if DEBUG
    /// The TikTok connect mockup, kept because it is the source of the screens in the Data
    /// Portability application — but there is no OAuth and no networking behind it, and its
    /// success screen states a favourite count it made up. Shipping it would be a
    /// non-functional demo the reviewer can reach (guideline 2.2), so the entry point, its
    /// state and its sheet all compile out of Release.
    private var connectPrototype: some View {
        Button { showConnect = true } label: {
            InfoChip(text: "Connect flow mockup", systemImage: "hammer.fill", tint: .stashInk.opacity(0.5))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showConnect) { ConnectFlowView() }
    }
    #endif

    private var subtitleLine: String {
        if usesCloudImport {
            if let status = controller.cloudStatus {
                switch status.state {
                case .accepted:
                    return "Queued for cloud processing · \(status.fastPass.total) videos — you can close the app"
                case .fastPass:
                    return "Fast pass \(status.fastPass.done) of \(status.fastPass.total) · \(status.unavailable) unavailable · \(status.partialFailures) partial failures — cloud keeps going if you close the app"
                case .completed:
                    return "Complete · \(status.unavailable) unavailable · \(status.partialFailures) partial failures"
                case .cancelled:
                    return "Cancelled · \(status.fastPass.done) of \(status.fastPass.total) processed"
                }
            }
            if controller.cloudSyncing { return "Refreshing cloud results…" }
            if let summary = controller.lastSummary { return summary }
            // Reached on a fresh account, so it says what tapping the card does rather than
            // what the build is configured for — this is the first line a reviewer reads.
            return "Pick your TikTok data export and Stash builds the library."
        }
        if let progress = controller.progress {
            return "\(progress.done) of \(progress.total) processed"
        }
        if let summary = controller.lastSummary { return summary }
        return "Sync the videos you favorite — or import an export below."
    }

    /// Guideline 5.1.2(i): the third parties that will see the library, named immediately above
    /// the button that hands it over — not in a policy page the user would have to go hunting
    /// for. The two names match the sub-processors the privacy policy lists, and the split is
    /// the real one: Groq gets the audio track, Bedrock gets text only.
    private var cloudDisclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Micro(text: "Processed in the cloud", size: 10, tracking: 1.8)
            Text("Stash servers download each video you submit. Its audio goes to Groq, Inc. "
                 + "(United States) for speech-to-text; the caption, transcript and on-screen "
                 + "text go to AWS Bedrock (Frankfurt) to write the summary and pick the "
                 + "category. The downloaded video is deleted straight after, and nothing is "
                 + "used to train models.")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: StashLegal.privacy) {
                Micro(text: "Read the privacy policy", size: 10, tracking: 1.2, color: .stashInk)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashOutlineCard()
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            cloudDisclosure
            StashPrimaryButton(title: usesCloudImport ? "Submit TikTok export" : "Import TikTok export", systemImage: "square.and.arrow.down") {
                showImporter = true
            }
            .disabled(controller.isImporting)
            .opacity(controller.isImporting ? 0.5 : 1)

            Button { showGuide = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                    Micro(text: "How to get your TikTok data", size: 10, tracking: 1.2, color: .stashInk.opacity(0.7))
                }
                .foregroundStyle(Color.stashInk.opacity(0.7))
            }
            .buttonStyle(.plain)

            // The share extension is invisible from inside the app, and a way in nobody knows
            // about is not a way in. One line, next to the other way of adding videos.
            HStack(spacing: 7) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                Micro(text: "Or share a TikTok to Stash to save just that one",
                      size: 10, tracking: 1.2, color: .stashInk.opacity(0.7))
            }
            .foregroundStyle(Color.stashInk.opacity(0.7))
        }
    }

    /// The budget counter, in the same outlined card as the box status. Settings is three taps
    /// deep (Library → Import → gear) and the number has to be readable *before* the user picks
    /// a file, not after the server refuses it. An exhausted budget is amber, not red: nothing
    /// broke and nothing is lost — the month simply has to turn over.
    private func quotaCard(_ quota: Quota) -> some View {
        let empty = quota.remaining == 0
        let accent: Color = empty ? .categoryOther : .categoryCoding
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Micro(text: "Budget", size: 10, tracking: 1.8)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: empty ? "hourglass" : "chart.bar.fill")
                        .font(.system(size: 12, weight: .bold))
                    Micro(text: empty ? "All spent" : "\(quota.remaining) left",
                          size: 10, tracking: 1.2, color: accent)
                }
                .foregroundStyle(accent)
            }
            Text(quotaSummary(quota))
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            // A shared TikTok is charged three times — importing it, transcribing it and
            // downloading it to read the frames — so the number is worth stating where the
            // budget is read rather than leaving it to be discovered by subtraction.
            Text("Sharing a TikTok into Stash costs 3: one to import it, one for the transcript, "
                 + "one to read the words on screen.")
                .font(.archivo(13, .semibold))
                .foregroundStyle(Color.stashInk.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashOutlineCard()
    }

    private func quotaSummary(_ quota: Quota) -> String {
        let resets = quota.monthResetDate.formatted(date: .abbreviated, time: .omitted)
        if quota.initialRemaining > 0 {
            return "\(quota.initialRemaining) of your \(quota.initialLimit) starting videos left, "
                + "then \(quota.monthLimit) a month."
        }
        if quota.monthRemaining > 0 {
            return "\(quota.monthRemaining) of \(quota.monthLimit) left this month · resets \(resets)."
        }
        return "This month's \(quota.monthLimit) are spent. \(quota.monthLimit) more on \(resets) — "
            + "everything already imported stays where it is."
    }

    private var boxCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Micro(text: "Model box", size: 10, tracking: 1.8)
                Spacer()
                HStack(spacing: 7) {
                    Image(systemName: controller.boxStatus.symbol)
                        .font(.system(size: 12, weight: .bold))
                    Micro(text: controller.boxStatus.label, size: 10, tracking: 1.2, color: controller.boxStatus.color)
                }
                .foregroundStyle(controller.boxStatus.color)
            }
            Button {
                Task { await controller.pingBox() }
            } label: {
                Micro(text: "Check again", size: 10, tracking: 1.4, color: .stashInk)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(Capsule().strokeBorder(Color.stashInk, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(controller.boxStatus == .checking)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .stashOutlineCard()
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Micro(text: "Library", size: 10, tracking: 1.8)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(librarySegments, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(count(category))")
                            .font(.archivo(26, .heavy))
                            .foregroundStyle(Color.stashOnAccent)
                        Micro(text: category.displayName, size: 10, tracking: 1.4, color: .stashOnAccent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(category.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            let flagged = videos.filter(\.needsLook).count
            if flagged > 0 {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12, weight: .bold))
                        Micro(text: "Needs a look", size: 10, tracking: 1.4, color: .categoryOther)
                    }
                    .foregroundStyle(Color.categoryOther)
                    Spacer()
                    Text("\(flagged)")
                        .font(.archivo(15, .heavy))
                        .foregroundStyle(Color.stashInk)
                        .monospacedDigit()
                }
                .stashOutlineCard()
            }
        }
    }

    // MARK: - Helpers

    private var localProgress: (done: Int, total: Int)? {
        guard !usesCloudImport else {
            guard let status = controller.cloudStatus else { return nil }
            return (status.fastPass.done, status.fastPass.total)
        }
        return controller.progress
    }

    private func count(_ category: Category) -> Int {
        videos.filter { !$0.needsLook && $0.category == category }.count
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await controller.runImport(url: url) }
        case .failure(let error):
            controller.lastError = error.localizedDescription
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var videos: [Video]
    private var controller = PipelineCenter.shared
    private var session = StashSession.shared
    @State private var confirmDelete = false
    @State private var isDeleting = false
    @State private var exportFile: URL?
    @State private var isExporting = false
    @State private var accountError: String?
    /// Saves still classified from the caption alone — the backfill's work queue.
    private var missingTranscripts: Int {
        videos.filter { !$0.unavailable && $0.transcript == nil }.count
    }
    /// Saves whose frames have not been read yet.
    private var missingVisualText: Int {
        videos.filter { !$0.unavailable && $0.ocrText == nil }.count
    }
    // Development-only overrides, and gated because of what the first one does: the base URL
    // is where `StashSession` posts the Apple identity token and the rotating refresh token,
    // and where every /v1 call carries the session JWT. An editable field in a shipping build
    // is a way to talk a user into handing all three to another host. The two model names
    // never had an effect to begin with — the server pins both.
    #if DEBUG
    @AppStorage("boxBaseURL") private var boxBaseURL = BoxDefaults.baseURL
    @AppStorage("chatModel") private var chatModel = BoxDefaults.chatModel
    @AppStorage("whisperModel") private var whisperModel = BoxDefaults.whisperModel
    @AppStorage(CloudImportFeatureFlag.forceLocalKey) private var forceLocalImport = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                if let quota = session.quota { quotaSection(quota) }
                #if DEBUG
                Section("Stash cloud") {
                    field("Base URL", text: $boxBaseURL, placeholder: BoxDefaults.baseURL, disableAutocaps: true)
                    field("Chat model", text: $chatModel, placeholder: BoxDefaults.chatModel)
                    field("Whisper model", text: $whisperModel, placeholder: BoxDefaults.whisperModel)
                }
                Section {
                    Text("Analysis and transcription run on the Stash cloud by default. Point the base URL at your own model box for local development — models are pinned server-side either way.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #endif
                // Every action here needs a real TikTok video id, and the seeded demo library's
                // ids are invented — on a reviewer's account these are buttons that can only
                // fail, and re-analyze would spend budget rewriting the curated sample.
                if StashSession.shared.isDemoAccount {
                    Section("Library") {
                        Text("This is a demo library, so the pipeline actions are off. Import your own TikTok export to enable them.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                Section("Library") {
                    Button {
                        controller.reanalyzeLibrary()
                    } label: {
                        if controller.isImporting, let p = controller.progress {
                            Text("Working… \(p.done)/\(p.total)")
                        } else {
                            Text("Re-analyze library (\(videos.count) videos)")
                        }
                    }
                    .disabled(controller.isImporting)
                    Text("Re-runs classification on every saved video against the current categories, using text already fetched — no re-download. Costs a few cents and can take several minutes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        controller.backfillTranscripts()
                    } label: {
                        Text("Fetch missing transcripts (\(missingTranscripts))")
                    }
                    .disabled(controller.isImporting || missingTranscripts == 0)
                    Text("Most saves were never transcribed, so their summaries come from the caption alone. This fetches the audio transcript and re-analyzes each one with it. It spends one unit of your budget per video, and transcription is rate-limited hourly, so run it again until the count reaches zero.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button {
                        controller.backfillVisualText()
                    } label: {
                        Text("Read on-screen text (\(missingVisualText))")
                    }
                    .disabled(controller.isImporting || missingVisualText == 0)
                    Text("Reads the words burned into each video's frames — often the real content on TikTok — and re-analyzes with them. Reading is done on your device, but each video has to be fetched through Stash first, so this spends one unit of your budget per video.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                }
                legalSection
                #if DEBUG
                Section("Developer") {
                    Toggle("Force on-device import", isOn: $forceLocalImport)
                    Text("Cloud import is the default — the box processes the whole library in the background. Enable this to run the on-device pipeline instead (local-box development).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // Guideline 5.1.1(v) asks for deletion the user can actually find and understand,
            // so the dialog names each store instead of saying "everything".
            .confirmationDialog("Delete your Stash account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete account and all data", role: .destructive) { deleteAccount() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("""
                    Deletes on the Stash server: your account, your sign-in, your remaining \
                    budget, and every import record and analysis result stored for you.
                    Deletes on this iPhone: all \(videos.count) saved videos with their \
                    transcripts and on-screen text, the cached thumbnails and album covers, \
                    and your session.
                    Your videos on TikTok are untouched. This cannot be undone.
                    """)
            }
        }
    }

    // MARK: - Account (App Store guideline 5.1.1(v): in-app deletion and data export)

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Signed in as") {
                Text(session.userID ?? "—")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button { exportData() } label: {
                if isExporting { Text("Preparing…") } else { Text("Export my data") }
            }
            .disabled(isExporting)
            // ShareLink is the share sheet; it only appears once there is a file to hand over.
            if let exportFile {
                ShareLink(item: exportFile) {
                    Label("Share the export", systemImage: "square.and.arrow.up")
                }
            }
            Text("Writes one JSON file with everything Stash holds about you: your imports, results and budget from the server, plus every save on this iPhone with its transcript and on-screen text.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Sign out") { session.signOut() }
            Button(role: .destructive) { confirmDelete = true } label: {
                if isDeleting { Text("Deleting…") } else { Text("Delete account") }
            }
            .disabled(isDeleting)
            if let accountError {
                Text(accountError).font(.footnote).foregroundStyle(Color.categoryRecipe)
            }
        }
    }

    /// Guideline 5.1.1(i): the sign-in gate links both documents, but a signed-in user has no
    /// way back to that screen, so Settings carries the second, permanent copy.
    private var legalSection: some View {
        Section("Legal") {
            Link("Terms of service", destination: StashLegal.terms)
            Link("Privacy policy", destination: StashLegal.privacy)
            Text("The privacy policy names everything Stash holds and the two providers that process it: Groq for speech-to-text, AWS for hosting and analysis.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func quotaSection(_ quota: Quota) -> some View {
        Section("Budget") {
            LabeledContent("Initial import", value: "\(quota.initialRemaining) of \(quota.initialLimit) left")
            LabeledContent("This month", value: "\(quota.monthRemaining) of \(quota.monthLimit) left")
            LabeledContent("Resets", value: quota.monthResetDate.formatted(date: .abbreviated, time: .omitted))
            Text("The initial budget is spent first. Importing a video, fetching its transcript and reading its on-screen text each cost one unit.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func exportData() {
        isExporting = true
        accountError = nil
        exportFile = nil
        Task {
            do {
                exportFile = try await writeExport()
            } catch {
                accountError = error.localizedDescription
            }
            isExporting = false
        }
    }

    /// One file with both halves of the user's data: what the box holds (import records,
    /// results, quota state) and what only this device holds (transcripts, on-screen text and
    /// the analysis attached to each save). Merged here because the box has never seen the
    /// local library, and an export that silently omits half of it is not an export.
    private func writeExport() async throws -> URL {
        let serverData = try await session.serverExport()
        // Embedded as parsed, not re-encoded field by field: whatever the box adds later ships
        // with it. An unparseable body is carried through as text rather than dropped.
        let server = (try? JSONSerialization.jsonObject(with: serverData))
            ?? ["unparsed": String(decoding: serverData, as: UTF8.self)]
        let payload: [String: Any] = [
            "exportedAt": Date().ISO8601Format(),
            "userID": session.userID ?? "",
            "server": server,
            "device": ["videos": videos.map(Self.exportRow)],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-export-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Every stored field of one save, listed by hand rather than reflected: adding a column to
    /// `Video` should be a deliberate decision about what the user is owed, not a silent gap.
    /// Optional values assign as `Any?`, so a nil transcript drops the key instead of writing null.
    private static func exportRow(_ video: Video) -> [String: Any] {
        var row: [String: Any] = [
            "videoID": video.videoID,
            "url": video.url.absoluteString,
            "bookmarkedAt": video.bookmarkedAt.ISO8601Format(),
            "author": video.author,
            "caption": video.caption,
            "hashtags": video.hashtags,
            "title": video.title,
            "summary": video.summary,
            "category": video.categoryRaw,
            "topics": video.topics,
            "unavailable": video.unavailable,
            "stages": video.stageStates.mapValues(\.rawValue),
        ]
        row["transcript"] = video.transcript
        row["ocrText"] = video.ocrText
        row["thumbnailURL"] = video.thumbnailURL?.absoluteString
        for (key, json) in [("recipe", video.recipeJSON), ("track", video.trackJSON),
                            ("music", video.musicJSON), ("code", video.codeJSON)] {
            if let json, let object = try? JSONSerialization.jsonObject(with: json) { row[key] = object }
        }
        return row
    }

    /// Server first: if the account deletion fails there is nothing to gain from wiping the
    /// device, and the user can retry. Only once the server is done do we drop local data —
    /// `session.deleteAccount` has already cleared the Keychain, so what is left here is the
    /// library, the cached pixels and the sync bookkeeping. Signing out flips RootView back
    /// to the gate on its own.
    private func deleteAccount() {
        isDeleting = true
        accountError = nil
        Task {
            do {
                try await session.deleteAccount()
            } catch {
                accountError = error.localizedDescription
                isDeleting = false
                return
            }
            try? context.delete(model: Video.self)
            try? context.save()
            try? FileManager.default.removeItem(at: ThumbnailStore.directory)
            try? FileManager.default.removeItem(at: AlbumStore.cacheURL)
            controller.forgetCloudState()
            isDeleting = false
            dismiss()
        }
    }

    #if DEBUG
    private func field(_ title: String, text: Binding<String>, placeholder: String, disableAutocaps: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(disableAutocaps ? .never : .sentences)
        }
    }
    #endif
}

#Preview {
    NavigationStack {
        ImportView()
    }
    .modelContainer(SampleData.previewContainer)
}
