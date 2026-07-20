// ImportView.swift
//
// The Import screen (pushed from Library), which doubles as pipeline status/history. It
// imports an extracted TikTok export (JSON file or folder), runs the pipeline via
// `PipelineRunner`, shows live progress and model-box reachability, and hosts the
// box-config settings sheet. Set List style: sync card, outlined status card, count grid.

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

/// Default box configuration: the cloud pipeline API. The bearer token is compiled
/// in from the gitignored generated file (scripts/gen-box-token.sh); Settings can
/// override everything for local-box development.
enum BoxDefaults {
    static let baseURL = "https://stash.dmitrijs.dev/v1"
    static let chatModel = "google.gemma-4-26b-a4b"   // pinned server-side; informational
    static let whisperModel = "whisper-large-v3-turbo" // pinned server-side; informational
    static let apiKey = BoxToken.value
}

func makeBoxConfig(baseURL: String, chatModel: String, whisperModel: String,
                   apiKey: String = BoxDefaults.apiKey) -> BoxConfig {
    BoxConfig(
        baseURL: URL(string: baseURL) ?? URL(string: "http://localhost:9")!,
        chatModel: chatModel,
        whisperModel: whisperModel,
        apiKey: apiKey
    )
}

// MARK: - View

struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var videos: [Video]
    private var controller = PipelineCenter.shared
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var showConnect = false
    @State private var showGuide = false

    @AppStorage("boxBaseURL") private var boxBaseURL = BoxDefaults.baseURL
    @AppStorage("boxApiKey") private var boxApiKey = BoxDefaults.apiKey
    @AppStorage("chatModel") private var chatModel = BoxDefaults.chatModel
    @AppStorage("whisperModel") private var whisperModel = BoxDefaults.whisperModel
    private var usesCloudImport: Bool { PipelineCenter.cloudImportEnabled }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                connectCard.padding(.top, 16)
                importSection.padding(.top, 12)
                if !usesCloudImport {
                    boxCard.padding(.top, 12)
                }
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
        .sheet(isPresented: $showConnect) { ConnectFlowView() }
        .sheet(isPresented: $showGuide) { DataDownloadGuideView() }
        .task {
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
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.stashInk)
                        .frame(width: 36, height: 36)
                        .background(Circle().strokeBorder(Color.stashInk, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
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

    /// The TikTok sync card: green when importing (with the progress bar), an invitation otherwise.
    private var connectCard: some View {
        Button { showConnect = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Micro(text: "TikTok", size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7))
                    Spacer()
                    Micro(
                        text: usesCloudImport ? "Cloud import" : (controller.isImporting ? "Syncing" : "Not connected"),
                        size: 9.5, tracking: 1.6, color: .stashOnAccent.opacity(0.7)
                    )
                }
                Text(usesCloudImport ? "Cloud import" : (controller.isImporting ? "Syncing favorites" : "Connect your TikTok"))
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
    }

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
            return "Developer cloud import is enabled."
        }
        if let progress = controller.progress {
            return "\(progress.done) of \(progress.total) processed"
        }
        if let summary = controller.lastSummary { return summary }
        return "Sync the videos you favorite — or import an export below."
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        }
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

    private var config: BoxConfig {
        makeBoxConfig(baseURL: boxBaseURL, chatModel: chatModel, whisperModel: whisperModel, apiKey: boxApiKey)
    }

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
    @Query private var videos: [Video]
    private var controller = PipelineCenter.shared
    /// Saves still classified from the caption alone — the backfill's work queue.
    private var missingTranscripts: Int {
        videos.filter { !$0.unavailable && $0.transcript == nil }.count
    }
    @AppStorage("boxBaseURL") private var boxBaseURL = BoxDefaults.baseURL
    @AppStorage("boxApiKey") private var boxApiKey = BoxDefaults.apiKey
    @AppStorage("chatModel") private var chatModel = BoxDefaults.chatModel
    @AppStorage("whisperModel") private var whisperModel = BoxDefaults.whisperModel
    #if DEBUG
    @AppStorage(CloudImportFeatureFlag.forceLocalKey) private var forceLocalImport = false
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Stash cloud") {
                    field("Base URL", text: $boxBaseURL, placeholder: BoxDefaults.baseURL, disableAutocaps: true)
                    LabeledContent("API key") {
                        SecureField("token", text: $boxApiKey)
                            .multilineTextAlignment(.trailing)
                    }
                    field("Chat model", text: $chatModel, placeholder: BoxDefaults.chatModel)
                    field("Whisper model", text: $whisperModel, placeholder: BoxDefaults.whisperModel)
                }
                Section {
                    Text("Analysis and transcription run on the Stash cloud by default. Point the base URL at your own model box for local development — models are pinned server-side either way.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                    Text("Most saves were never transcribed, so their summaries come from the caption alone. This fetches the audio transcript and re-analyzes each one with it. Transcription is rate-limited hourly, so run it again until the count reaches zero.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
        }
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, disableAutocaps: Bool = false) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(disableAutocaps ? .never : .sentences)
        }
    }
}

#Preview {
    NavigationStack {
        ImportView()
    }
    .modelContainer(SampleData.previewContainer)
}
