import AppKit
import CaptionBridgeCore
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayController: SubtitleOverlayController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If the Whisper helper dies while we are writing audio to its pipe,
        // the failure must surface as a Swift error, never as a SIGPIPE that
        // terminates the app mid-meeting.
        signal(SIGPIPE, SIG_IGN)
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
