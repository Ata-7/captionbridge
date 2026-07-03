import AppKit
import CaptionBridgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: SubtitleOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func attach(viewModel: CaptionBridgeViewModel) {
        guard overlayController == nil else {
            return
        }

        let controller = SubtitleOverlayController(viewModel: viewModel)
        overlayController = controller
        viewModel.overlayController = controller
    }
}
