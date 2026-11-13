import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if #available(iOS 13.0, *) {
            // The scene delegate owns the window on iOS 13 and later.
        } else {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = MainViewController()
            window.makeKeyAndVisible()
            self.window = window
        }
        application.isIdleTimerDisabled = true
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        application.isIdleTimerDisabled = false
    }
}

@available(iOS 13.0, *)
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = MainViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}
