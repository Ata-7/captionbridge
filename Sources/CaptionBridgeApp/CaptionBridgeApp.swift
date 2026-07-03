import CaptionBridgeCore
import SwiftUI

@main
struct CaptionBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = CaptionBridgeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 520, minHeight: 520)
                .onAppear {
                    appDelegate.attach(viewModel: viewModel)
                    viewModel.configureLaunchDiagnosticsIfNeeded()
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}
