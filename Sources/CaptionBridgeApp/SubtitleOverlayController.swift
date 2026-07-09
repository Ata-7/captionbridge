import AppKit
import CaptionBridgeCore
import SwiftUI
#if canImport(Translation)
import Translation
#endif

@MainActor
final class SubtitleOverlayController {
    private let viewModel: CaptionBridgeViewModel
    private var panel: NSPanel?

    init(viewModel: CaptionBridgeViewModel) {
        self.viewModel = viewModel
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        clampToVisibleScreen(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func refreshLayoutForCurrentSettings() {
        guard let panel else {
            return
        }

        // Adopt the new size but keep the position the user dragged it to.
        let metrics = Self.defaultOverlayFrame(for: viewModel.settings.subtitleOverlaySize)
        var frame = panel.frame
        frame.size = metrics.size
        panel.minSize = Self.minimumOverlaySize(for: viewModel.settings.subtitleOverlaySize)
        panel.setFrame(frame, display: true, animate: false)
        clampToVisibleScreen(panel)
    }

    private func makePanel() -> NSPanel {
        let overlayView = SubtitleOverlayView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let initialFrame = Self.defaultOverlayFrame(for: viewModel.settings.subtitleOverlaySize)
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.title = "CaptionBridge Subtitles"
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.minSize = Self.minimumOverlaySize(for: viewModel.settings.subtitleOverlaySize)
        panel.isMovableByWindowBackground = true
        panel.contentView = hostingView
        // Remember where the user left the overlay between launches.
        panel.setFrameAutosaveName("CaptionBridgeOverlay")

        return panel
    }

    private static func defaultOverlayFrame(for size: CaptionBridgeCore.SubtitleOverlaySize) -> NSRect {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let metrics = OverlayMetrics(size: size)
        let width = min(metrics.defaultWidth, screenFrame.width - 48)
        let height = metrics.defaultHeight
        return NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.minY + 72,
            width: width,
            height: height
        )
    }

    private static func minimumOverlaySize(for size: CaptionBridgeCore.SubtitleOverlaySize) -> NSSize {
        let metrics = OverlayMetrics(size: size)
        return NSSize(width: metrics.minimumWidth, height: metrics.minimumHeight)
    }

    private func clampToVisibleScreen(_ panel: NSPanel) {
        guard let screenFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return
        }

        var frame = panel.frame
        if frame.width > screenFrame.width {
            frame.size.width = screenFrame.width - 32
        }
        if frame.height > screenFrame.height {
            frame.size.height = screenFrame.height - 32
        }

        frame.origin.x = min(
            max(frame.origin.x, screenFrame.minX + 16),
            screenFrame.maxX - frame.width - 16
        )
        frame.origin.y = min(
            max(frame.origin.y, screenFrame.minY + 16),
            screenFrame.maxY - frame.height - 16
        )

        panel.setFrame(frame, display: false)
    }
}

struct SubtitleOverlayView: View {
    @ObservedObject var viewModel: CaptionBridgeViewModel
    @State private var pointerInsideHistory = false
    @State private var scrollToLatest = 0

    var body: some View {
        let metrics = OverlayMetrics(size: viewModel.settings.subtitleOverlaySize)

        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.black.opacity(0.72))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.14), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 7) {
                DragHandle()
                    .frame(height: 18)

                if hasCaptionContent {
                    scrollableCaptionHistory(metrics: metrics)
                } else {
                    Text(displayText)
                        .font(.system(size: metrics.statusFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel(displayText)
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.bottom, metrics.bottomPadding)
            .background(instantDraftTranslationBridge)

            if hasCaptionContent {
                Button {
                    scrollToLatest += 1
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white.opacity(pointerInsideHistory ? 0.9 : 0.5))
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(.top, 28)
                .padding(.trailing, 18)
                .help("Jump to latest captions")
            }
        }
    }

    @ViewBuilder
    private var instantDraftTranslationBridge: some View {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            InstantDraftTranslationBridge(viewModel: viewModel)
        }
        #endif
    }

    private func scrollableCaptionHistory(metrics: OverlayMetrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: metrics.rowSpacing) {
                    ForEach(Array(overlayFinals.enumerated()), id: \.element.id) { index, item in
                        let isLatestFinal = index == overlayFinals.count - 1
                        captionRow(
                            text: item.text,
                            sourceText: item.sourceText,
                            isLatestFinal: isLatestFinal,
                            opacity: opacity(for: index, totalCount: overlayFinals.count),
                            metrics: metrics
                        )
                    }

                    if hasDraftContent {
                        captionRow(
                            text: viewModel.draftSubtitle,
                            sourceText: viewModel.draftSourceText,
                            isLatestFinal: false,
                            opacity: 0.72,
                            isDraft: true,
                            metrics: metrics
                        )
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("latest-caption-anchor")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .defaultScrollAnchor(.bottom)
            .onHover { pointerInsideHistory = $0 }
            .onAppear {
                scrollToLatestCaption(proxy)
            }
            .onChange(of: viewModel.sessionTranscript.count) {
                guard !pointerInsideHistory else {
                    return
                }
                scrollToLatestCaption(proxy)
            }
            .onChange(of: viewModel.draftSubtitle) {
                guard !pointerInsideHistory else {
                    return
                }
                scrollToLatestCaption(proxy)
            }
            .onChange(of: viewModel.draftSourceText) {
                guard !pointerInsideHistory else {
                    return
                }
                scrollToLatestCaption(proxy)
            }
            .onChange(of: scrollToLatest) {
                scrollToLatestCaption(proxy)
            }
        }
    }

    private func captionRow(
        text: String,
        sourceText: String?,
        isLatestFinal: Bool,
        opacity: Double,
        isDraft: Bool = false,
        metrics: OverlayMetrics
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.settings.subtitleDisplayMode == .bilingual,
               let sourceText,
               !sourceText.isEmpty {
                Text(sourceText)
                    .font(.system(size: sourceFontSize(isLatestFinal: isLatestFinal, isDraft: isDraft, hasTranslation: !text.isEmpty, metrics: metrics), weight: isDraft ? .medium : .regular))
                    .foregroundStyle(.white.opacity(sourceOpacity(isDraft: isDraft, hasTranslation: !text.isEmpty) * opacity))
                    .lineLimit(sourceLineLimit(isLatestFinal: isLatestFinal, isDraft: isDraft, metrics: metrics))
                    .lineSpacing(2)
                    .minimumScaleFactor(0.72)
            }

            if !text.isEmpty {
                Text(text)
                    .font(.system(size: fontSize(isLatestFinal: isLatestFinal, isDraft: isDraft, metrics: metrics), weight: isDraft ? .regular : .semibold))
                    .foregroundStyle(.white.opacity(opacity))
                    .multilineTextAlignment(.leading)
                    .lineLimit(lineLimit(isLatestFinal: isLatestFinal, isDraft: isDraft, metrics: metrics))
                    .lineSpacing(3)
                    .minimumScaleFactor(0.75)
                    .accessibilityLabel(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overlayFinals: [SubtitleHistoryItem] {
        viewModel.sessionTranscript.isEmpty ? viewModel.subtitleHistory : viewModel.sessionTranscript
    }

    private var displayText: String {
        let liveStatus = viewModel.liveStatus
        if liveStatus != "Idle" {
            return liveStatus
        }

        return "Waiting for speech..."
    }

    private var hasCaptionContent: Bool {
        !overlayFinals.isEmpty || hasDraftContent
    }

    private var hasDraftContent: Bool {
        if !viewModel.draftSubtitle.isEmpty {
            return true
        }

        guard viewModel.settings.subtitleDisplayMode == .bilingual else {
            return false
        }

        return !(viewModel.draftSourceText?.isEmpty ?? true)
    }

    private func opacity(for index: Int, totalCount: Int) -> Double {
        guard totalCount > 1 else {
            return 1
        }

        let age = totalCount - index - 1
        switch age {
        case 0:
            return 1
        case 1:
            return 0.82
        default:
            return 0.64
        }
    }

    private func fontSize(isLatestFinal: Bool, isDraft: Bool, metrics: OverlayMetrics) -> CGFloat {
        if isDraft {
            return metrics.draftFontSize
        }

        return isLatestFinal ? metrics.latestFinalFontSize : metrics.previousFinalFontSize
    }

    private func sourceFontSize(isLatestFinal: Bool, isDraft: Bool, hasTranslation: Bool, metrics: OverlayMetrics) -> CGFloat {
        if isDraft && !hasTranslation {
            return metrics.sourceDraftOnlyFontSize
        }

        if isLatestFinal {
            return metrics.latestSourceFontSize
        }

        return metrics.previousSourceFontSize
    }

    private func sourceOpacity(isDraft: Bool, hasTranslation: Bool) -> Double {
        isDraft && !hasTranslation ? 0.96 : 0.84
    }

    private func scrollToLatestCaption(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("latest-caption-anchor", anchor: .bottom)
            }
        }
    }

    private func lineLimit(isLatestFinal: Bool, isDraft: Bool, metrics: OverlayMetrics) -> Int {
        if isDraft {
            return metrics.draftLineLimit
        }

        return isLatestFinal ? metrics.latestFinalLineLimit : metrics.previousFinalLineLimit
    }

    private func sourceLineLimit(isLatestFinal: Bool, isDraft: Bool, metrics: OverlayMetrics) -> Int {
        if isDraft {
            return metrics.draftSourceLineLimit
        }

        return isLatestFinal ? metrics.latestSourceLineLimit : metrics.previousSourceLineLimit
    }
}

private struct OverlayMetrics {
    let defaultWidth: CGFloat
    let defaultHeight: CGFloat
    let minimumWidth: CGFloat
    let minimumHeight: CGFloat
    let latestFinalFontSize: CGFloat
    let previousFinalFontSize: CGFloat
    let draftFontSize: CGFloat
    let latestSourceFontSize: CGFloat
    let previousSourceFontSize: CGFloat
    let sourceDraftOnlyFontSize: CGFloat
    let statusFontSize: CGFloat
    let horizontalPadding: CGFloat
    let bottomPadding: CGFloat
    let rowSpacing: CGFloat
    let latestFinalLineLimit: Int
    let previousFinalLineLimit: Int
    let draftLineLimit: Int
    let latestSourceLineLimit: Int
    let previousSourceLineLimit: Int
    let draftSourceLineLimit: Int

    init(size: CaptionBridgeCore.SubtitleOverlaySize) {
        switch size {
        case .compact:
            defaultWidth = 740
            defaultHeight = 275
            minimumWidth = 560
            minimumHeight = 205
            latestFinalFontSize = 23
            previousFinalFontSize = 18
            draftFontSize = 19
            latestSourceFontSize = 16
            previousSourceFontSize = 14
            sourceDraftOnlyFontSize = 18
            statusFontSize = 23
            horizontalPadding = 22
            bottomPadding = 18
            rowSpacing = 7
            latestFinalLineLimit = 3
            previousFinalLineLimit = 2
            draftLineLimit = 2
            latestSourceLineLimit = 2
            previousSourceLineLimit = 2
            draftSourceLineLimit = 2
        case .comfortable:
            defaultWidth = 860
            defaultHeight = 340
            minimumWidth = 620
            minimumHeight = 250
            latestFinalFontSize = 25
            previousFinalFontSize = 21
            draftFontSize = 22
            latestSourceFontSize = 18
            previousSourceFontSize = 16
            sourceDraftOnlyFontSize = 21
            statusFontSize = 26
            horizontalPadding = 26
            bottomPadding = 22
            rowSpacing = 9
            latestFinalLineLimit = 3
            previousFinalLineLimit = 3
            draftLineLimit = 2
            latestSourceLineLimit = 2
            previousSourceLineLimit = 2
            draftSourceLineLimit = 2
        case .large:
            defaultWidth = 980
            defaultHeight = 410
            minimumWidth = 700
            minimumHeight = 300
            latestFinalFontSize = 29
            previousFinalFontSize = 24
            draftFontSize = 25
            latestSourceFontSize = 21
            previousSourceFontSize = 18
            sourceDraftOnlyFontSize = 24
            statusFontSize = 29
            horizontalPadding = 30
            bottomPadding = 26
            rowSpacing = 10
            latestFinalLineLimit = 4
            previousFinalLineLimit = 3
            draftLineLimit = 2
            latestSourceLineLimit = 2
            previousSourceLineLimit = 2
            draftSourceLineLimit = 2
        }
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct InstantDraftTranslationBridge: View {
    @ObservedObject var viewModel: CaptionBridgeViewModel
    @State private var configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "fr"),
        target: Locale.Language(identifier: "en")
    )

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                await viewModel.runInstantDraftTranslation(session: session)
            }
    }
}
#endif

struct DragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView {
        DragHandleView()
    }

    func updateNSView(_ nsView: DragHandleView, context: Context) {}
}

final class DragHandleView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.28).setFill()
        let rect = NSRect(x: bounds.midX - 28, y: bounds.midY - 2, width: 56, height: 4)
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
