import AppKit
import CaptionBridgeCore
import SwiftUI
#if canImport(Translation)
@preconcurrency import Translation
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
        if panel.frame.height < panel.minSize.height {
            var frame = panel.frame
            frame.size.height = panel.minSize.height
            panel.setFrame(frame, display: false)
        }

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
    @State private var scrollToLatest = 0
    @State private var followsLatest = true

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
                    VStack(alignment: .leading, spacing: 7) {
                        scrollableFinalHistory(metrics: metrics)

                        Divider()
                            .overlay(.white.opacity(0.12))

                        liveDraftArea(metrics: metrics)
                    }
                } else {
                    Text(displayText)
                        .font(.system(size: metrics.statusFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .accessibilityLabel(displayText)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.bottom, metrics.bottomPadding)
            .background(instantDraftTranslationBridge)

            if !overlayFinals.isEmpty, !followsLatest {
                Button {
                    followsLatest = true
                    scrollToLatest += 1
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to latest captions")
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

    private func scrollableFinalHistory(metrics: OverlayMetrics) -> some View {
        ScrollViewReader { proxy in
            let historyScrollView = ScrollView {
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

                    Color.clear
                        .frame(height: 1)
                        .id("latest-caption-anchor")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    HistoryScrollObserver { isAtLatest in
                        followsLatest = isAtLatest
                    }
                )
            }
            .scrollIndicators(.visible)

            trackHistoryPosition(historyScrollView)
            .onAppear {
                scrollToLatestCaption(proxy)
            }
            .onChange(of: viewModel.sessionTranscript.count) {
                guard followsLatest else {
                    return
                }
                scrollToLatestCaption(proxy)
            }
            .onChange(of: viewModel.subtitleHistory.count) {
                guard viewModel.sessionTranscript.isEmpty, followsLatest else {
                    return
                }
                scrollToLatestCaption(proxy)
            }
            .onChange(of: scrollToLatest) {
                scrollToLatestCaption(proxy)
            }
        }
    }

    @ViewBuilder
    private func trackHistoryPosition<Content: View>(_ content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height + 8
                    || geometry.visibleRect.maxY >= geometry.contentSize.height - 8
            } action: { _, isAtLatest in
                followsLatest = isAtLatest
            }
        } else {
            content
        }
    }

    private func liveDraftArea(metrics: OverlayMetrics) -> some View {
        let sourceText = viewModel.settings.subtitleDisplayMode == .bilingual
            ? (viewModel.draftSourceText ?? "")
            : ""
        let translatedText = viewModel.draftSubtitle
        let isBilingual = viewModel.settings.subtitleDisplayMode == .bilingual
        let bilingualRowHeight = (metrics.draftAreaHeight - 4) / 2

        return VStack(alignment: .leading, spacing: 4) {
            if isBilingual {
                Text(sourceText)
                    .font(.system(size: metrics.sourceDraftOnlyFontSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(metrics.draftSourceLineLimit)
                    .lineSpacing(2)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity, minHeight: bilingualRowHeight, maxHeight: bilingualRowHeight, alignment: .topLeading)
            }

            Text(translatedText)
                .font(.system(size: metrics.draftFontSize, weight: .regular))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(metrics.draftLineLimit)
                .lineSpacing(3)
                .minimumScaleFactor(0.75)
                .frame(
                    maxWidth: .infinity,
                    minHeight: isBilingual ? bilingualRowHeight : metrics.draftAreaHeight,
                    maxHeight: isBilingual ? bilingualRowHeight : metrics.draftAreaHeight,
                    alignment: .topLeading
                )
        }
        .frame(height: metrics.draftAreaHeight, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(draftAccessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
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
        !viewModel.draftSubtitle.isEmpty || !(viewModel.draftSourceText?.isEmpty ?? true)
    }

    private var draftAccessibilityLabel: String {
        var lines: [String] = []
        if viewModel.settings.subtitleDisplayMode == .bilingual,
           let sourceText = viewModel.draftSourceText,
           !sourceText.isEmpty {
            lines.append("French: \(sourceText)")
        }
        if !viewModel.draftSubtitle.isEmpty {
            lines.append("English: \(viewModel.draftSubtitle)")
        }
        return lines.isEmpty ? "Live caption waiting" : lines.joined(separator: ". ")
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
            return 0.9
        default:
            return 0.78
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
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
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

private struct HistoryScrollObserver: NSViewRepresentable {
    let onUserScroll: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll)
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.observer = context.coordinator
        view.connectToScrollView()
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        nsView.observer = context.coordinator
        nsView.connectToScrollView()
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onUserScroll: (Bool) -> Void
        private weak var scrollView: NSScrollView?

        init(onUserScroll: @escaping (Bool) -> Void) {
            self.onUserScroll = onUserScroll
        }

        func attach(to scrollView: NSScrollView?) {
            guard self.scrollView !== scrollView else {
                return
            }

            detach()
            self.scrollView = scrollView
            guard let scrollView else {
                return
            }

            let center = NotificationCenter.default
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                center.addObserver(
                    self,
                    selector: #selector(handleScrollNotification),
                    name: name,
                    object: scrollView
                )
            }
            scrollView.contentView.postsBoundsChangedNotifications = true
            center.addObserver(
                self,
                selector: #selector(handleScrollNotification),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            reportPosition()
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            scrollView = nil
        }

        @objc private func handleScrollNotification(_ notification: Notification) {
            reportPosition()
        }

        private func reportPosition() {
            guard let scrollView, let documentView = scrollView.documentView else {
                return
            }

            let visibleRect = scrollView.contentView.documentVisibleRect
            let documentBounds = documentView.bounds
            let tolerance: CGFloat = 8
            let isAtLatest: Bool
            if documentBounds.height <= visibleRect.height + tolerance {
                isAtLatest = true
            } else if let verticalScroller = scrollView.verticalScroller {
                isAtLatest = verticalScroller.doubleValue >= 0.99
            } else if documentView.isFlipped {
                isAtLatest = visibleRect.maxY >= documentBounds.maxY - tolerance
            } else {
                isAtLatest = visibleRect.minY <= documentBounds.minY + tolerance
            }
            onUserScroll(isAtLatest)
        }
    }

    @MainActor
    final class ProbeView: NSView {
        weak var observer: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connectToScrollView()
        }

        func connectToScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                observer?.attach(to: enclosingScrollView)
            }
        }
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
    let draftAreaHeight: CGFloat

    init(size: CaptionBridgeCore.SubtitleOverlaySize) {
        switch size {
        case .compact:
            defaultWidth = 740
            defaultHeight = 350
            minimumWidth = 560
            minimumHeight = 330
            latestFinalFontSize = 17
            previousFinalFontSize = 16
            draftFontSize = 16
            latestSourceFontSize = 13
            previousSourceFontSize = 12
            sourceDraftOnlyFontSize = 14
            statusFontSize = 20
            horizontalPadding = 22
            bottomPadding = 18
            rowSpacing = 7
            latestFinalLineLimit = 2
            previousFinalLineLimit = 2
            draftLineLimit = 2
            latestSourceLineLimit = 2
            previousSourceLineLimit = 2
            draftSourceLineLimit = 2
            draftAreaHeight = 78
        case .comfortable:
            defaultWidth = 860
            defaultHeight = 390
            minimumWidth = 620
            minimumHeight = 340
            latestFinalFontSize = 19
            previousFinalFontSize = 17
            draftFontSize = 18
            latestSourceFontSize = 15
            previousSourceFontSize = 13
            sourceDraftOnlyFontSize = 16
            statusFontSize = 23
            horizontalPadding = 26
            bottomPadding = 22
            rowSpacing = 9
            latestFinalLineLimit = 3
            previousFinalLineLimit = 3
            draftLineLimit = 2
            latestSourceLineLimit = 2
            previousSourceLineLimit = 2
            draftSourceLineLimit = 2
            draftAreaHeight = 84
        case .large:
            defaultWidth = 980
            defaultHeight = 460
            minimumWidth = 700
            minimumHeight = 390
            latestFinalFontSize = 22
            previousFinalFontSize = 19
            draftFontSize = 20
            latestSourceFontSize = 17
            previousSourceFontSize = 15
            sourceDraftOnlyFontSize = 18
            statusFontSize = 26
            horizontalPadding = 30
            bottomPadding = 26
            rowSpacing = 10
            latestFinalLineLimit = 4
            previousFinalLineLimit = 3
            draftLineLimit = 2
            latestSourceLineLimit = 2
            previousSourceLineLimit = 2
            draftSourceLineLimit = 2
            draftAreaHeight = 96
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
