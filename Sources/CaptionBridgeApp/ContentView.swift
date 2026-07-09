import CaptionBridgeCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: CaptionBridgeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                setupGrid
                    .onChange(of: viewModel.settings) {
                        viewModel.saveSettings()
                    }
                    .onChange(of: viewModel.settings.subtitleOverlaySize) {
                        viewModel.refreshOverlayLayout()
                    }

                modelPanel
                privacyPanel
                controls
                previewPanel
                sessionHistoryPanel

                errorPanel
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 700, minHeight: 520)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.blue.opacity(0.14))
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 5) {
                Text("CaptionBridge")
                    .font(.system(size: 30, weight: .semibold))
                Text("Private live translated subtitles for every meeting app.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge
        }
    }

    @ViewBuilder
    private var errorPanel: some View {
        if let error = viewModel.lastError {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)

                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer()

                if viewModel.canOpenPrivacySettings {
                    Button {
                        viewModel.openPrivacySettings()
                    } label: {
                        Label("Open Privacy Settings", systemImage: "gearshape")
                    }
                    .controlSize(.regular)
                }
            }
            .padding(12)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.55), in: Capsule())
    }

    private var statusText: String {
        switch viewModel.sessionState {
        case .idle:
            return "Idle"
        case .preparing:
            return "Preparing"
        case .running:
            return "Live"
        case .paused:
            return "Paused"
        case .failed:
            return "Needs attention"
        }
    }

    private var statusColor: Color {
        switch viewModel.sessionState {
        case .idle:
            return .secondary
        case .preparing:
            return .orange
        case .running:
            return .green
        case .paused:
            return .yellow
        case .failed:
            return .red
        }
    }

    private var setupGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                pickerCard(title: "Input", icon: "speaker.wave.2") {
                    Picker("Input source", selection: $viewModel.settings.audioSource) {
                        ForEach(AudioSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .labelsHidden()
                    .disabled(isSessionActive)
                    .help(isSessionActive ? "Stop subtitles before switching the input source" : "Choose where meeting audio comes from")
                }

                pickerCard(title: "Language", icon: "globe") {
                    Picker("Spoken -> subtitles", selection: $viewModel.settings.languagePair) {
                        ForEach(LanguagePair.allCases) { pair in
                            Text(pair.displayName).tag(pair)
                        }
                    }
                    .labelsHidden()
                }
            }

            GridRow {
                pickerCard(title: "Display", icon: "text.bubble") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Subtitle display", selection: $viewModel.settings.subtitleDisplayMode) {
                            ForEach(SubtitleDisplayMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()

                        Picker("Overlay size", selection: $viewModel.settings.subtitleOverlaySize) {
                            ForEach(SubtitleOverlaySize.allCases) { size in
                                Text(size.displayName).tag(size)
                            }
                        }
                        .labelsHidden()

                        if viewModel.supportsInstantEnglishDrafts {
                            Toggle("Instant English drafts", isOn: $viewModel.settings.instantEnglishDraftsEnabled)
                                .toggleStyle(.checkbox)
                                .font(.caption)
                                .help("Translates the live French line into English on-device (Apple Translation) while the speaker is still talking. The polished final caption still comes from Whisper.")
                        }
                    }
                }

                pickerCard(title: "Model", icon: "cpu") {
                    Picker("Local model", selection: $viewModel.settings.selectedModelID) {
                        ForEach(viewModel.modelDescriptors) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(isSessionActive)
                    .help(isSessionActive ? "Stop subtitles before switching models" : "Choose the local Whisper model")
                }
            }
        }
    }

    private func pickerCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var modelPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "shippingbox")
                Text(viewModel.modelStatus)
                Spacer()
                if viewModel.modelDownloadProgress != nil {
                    Button {
                        viewModel.cancelModelDownload()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        viewModel.downloadSelectedModel()
                    } label: {
                        Label(viewModel.isSelectedModelInstalled ? "Installed" : "Download", systemImage: viewModel.isSelectedModelInstalled ? "checkmark.circle" : "arrow.down.circle")
                    }
                    .disabled(viewModel.isSelectedModelInstalled)
                }
            }

            if let progress = viewModel.modelDownloadProgress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text("\(Int((progress * 100).rounded()))% downloaded. The recommended model is large and only downloads once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Image(systemName: viewModel.helperStatus.contains("ready") ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(viewModel.helperStatus.contains("ready") ? .green : .orange)
                Text(viewModel.helperStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var privacyPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.title3)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text("Local only: audio never leaves this Mac")
                    .font(.headline)
                Text("Raw audio stays in memory. The overlay keeps temporary scrollback for the current session, but captions are not saved to disk, cloud inference is disabled, and analytics are off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                viewModel.startSubtitles()
            } label: {
                Label("Start Subtitles", systemImage: "play.fill")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isSessionActive || !viewModel.canStartSubtitles)
            .help(viewModel.canStartSubtitles ? "Start translated subtitles" : "Download the local model and make sure the local translator is ready first")

            Button {
                viewModel.pauseOrResume()
            } label: {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
            }
            .controlSize(.large)
            .disabled(!canPauseOrResume)

            Button {
                viewModel.stopSubtitles()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.large)
            .disabled(!canStop)

            Button {
                viewModel.clearCaptions()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .controlSize(.large)

            Spacer()

            Button {
                viewModel.toggleOverlay()
            } label: {
                Label(viewModel.isOverlayVisible ? "Hide Overlay" : "Show Overlay", systemImage: "captions.bubble")
            }
            .controlSize(.large)
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subtitle Preview")
                .font(.headline)

            Text(viewModel.liveStatus)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(viewModel.subtitleHistory) { item in
                    captionPreviewRow(item, isLatest: item == viewModel.subtitleHistory.last)
                }

                if !viewModel.draftSubtitle.isEmpty || !(viewModel.draftSourceText?.isEmpty ?? true) {
                    VStack(alignment: .leading, spacing: 2) {
                        if viewModel.settings.subtitleDisplayMode == .bilingual,
                           let source = viewModel.draftSourceText,
                           !source.isEmpty {
                            Text(source)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if !viewModel.draftSubtitle.isEmpty {
                            Text(viewModel.draftSubtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if viewModel.subtitleHistory.isEmpty,
                   viewModel.draftSubtitle.isEmpty,
                   (viewModel.draftSourceText?.isEmpty ?? true) {
                    Text(previewText)
                        .font(.title3.weight(.medium))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sessionHistoryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Session History")
                    .font(.headline)
                Text("\(viewModel.sessionTranscript.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.45), in: Capsule())
                Spacer()
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if viewModel.sessionTranscript.isEmpty {
                        Text("No captions yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 82, alignment: .center)
                    } else {
                        ForEach(viewModel.sessionTranscript.reversed()) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)

                                if viewModel.settings.subtitleDisplayMode == .bilingual,
                                   let source = item.sourceText,
                                   !source.isEmpty {
                                    Text(source)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Text(item.text)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            if item.id != viewModel.sessionTranscript.first?.id {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 190)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func captionPreviewRow(_ item: SubtitleHistoryItem, isLatest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.settings.subtitleDisplayMode == .bilingual,
               let source = item.sourceText,
               !source.isEmpty {
                Text(source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(item.text)
                .font(.callout.weight(.medium))
                .foregroundStyle(isLatest ? .primary : .secondary)
                .lineLimit(2)
        }
    }

    private var isSessionActive: Bool {
        switch viewModel.sessionState {
        case .preparing, .running, .paused:
            return true
        case .idle, .failed:
            return false
        }
    }

    private var canPauseOrResume: Bool {
        switch viewModel.sessionState {
        case .running, .paused:
            return true
        case .idle, .preparing, .failed:
            return false
        }
    }

    private var canStop: Bool {
        switch viewModel.sessionState {
        case .running, .paused:
            return true
        case .idle, .preparing, .failed:
            return false
        }
    }

    private var isPaused: Bool {
        if case .paused = viewModel.sessionState {
            return true
        }
        return false
    }

    private var previewText: String {
        if !viewModel.currentSubtitle.isEmpty {
            return viewModel.currentSubtitle
        }

        if !viewModel.draftSubtitle.isEmpty {
            return viewModel.draftSubtitle
        }

        if viewModel.settings.subtitleDisplayMode == .bilingual,
           let source = viewModel.draftSourceText,
           !source.isEmpty {
            return source
        }

        return viewModel.liveStatus == "Idle" ? "Subtitles will appear here after local speech translation starts." : viewModel.liveStatus
    }
}
