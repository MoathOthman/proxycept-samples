import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

@main final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var factory: RCTReactNativeFactory?
    private var delegate: ExampleDelegate?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let delegate = ExampleDelegate()
        delegate.dependencyProvider = RCTAppDependencyProvider()
        let factory = RCTReactNativeFactory(delegate: delegate)
        self.delegate = delegate; self.factory = factory
        window = UIWindow(frame: UIScreen.main.bounds)
        let url = ProcessInfo.processInfo.environment["PROXYCEPT_TEST_CONFIG_URL"]
            ?? "http://127.0.0.1:18881/sdk-test-config"
        factory.startReactNative(withModuleName: "ProxyceptRNExample", in: window,
            initialProperties: ["configURL": url], launchOptions: launchOptions)
        return true
    }
}
final class ExampleDelegate: RCTDefaultReactNativeFactoryDelegate {
    override func sourceURL(for bridge: RCTBridge) -> URL? { bundleURL() }
    override func bundleURL() -> URL? { Bundle.main.url(forResource: "main", withExtension: "jsbundle") }
}
