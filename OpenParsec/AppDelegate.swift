import UIKit
import AVFoundation

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private(set) var coordinator: AppCoordinator?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        let coordinator = AppCoordinator(window: window)
        self.coordinator = coordinator
        coordinator.start()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if #available(iOS 15, *) { PictureInPictureManager.shared.stopPiP() }
        ParsecBackgroundManager.shared.sceneDidBecomeActive()
    }

    func applicationWillResignActive(_ application: UIApplication) {
        ParsecBackgroundManager.shared.sceneWillResignActive()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        var pipAttempted = false
        if #available(iOS 15, *), ParsecBackgroundManager.shared.hasActiveConnection {
            PictureInPictureManager.shared.startPiP()
            pipAttempted = PictureInPictureManager.shared.isPiPActive || PictureInPictureManager.shared.isStarting
        }
        if !pipAttempted && ParsecBackgroundManager.shared.hasActiveConnection {
            ParsecBackgroundManager.shared.onShouldDisconnect?()
        }
        ParsecBackgroundManager.shared.sceneDidEnterBackground()
    }

    func applicationWillTerminate(_ application: UIApplication) { CParsec.destroy() }
}
