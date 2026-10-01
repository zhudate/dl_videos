import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == DownloadManager.backgroundIdentifier {
            DownloadManager.shared.backgroundEventsCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}

@main
struct HLSBridgeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var manager = DownloadManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
                .onOpenURL { manager.handleIncomingURL($0) }
                .onAppear { manager.setAppActive(scenePhase == .active) }
                .onChange(of: scenePhase) { phase in manager.setAppActive(phase == .active) }
        }
    }
}
