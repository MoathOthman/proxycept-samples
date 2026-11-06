import SwiftUI
import ProxyceptLogging

/// Standalone simulator smoke app. All networking is performed by the package.
@main
struct LoopbackDemoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = "Starting…"
    private let logger: ProxyceptLogger?
    private let startupError: String?

    init() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("ProxyceptLoopbackDemo", isDirectory: true)
            let environment = ProcessInfo.processInfo.environment
            // This fallback is a public dummy fixture for the included loopback server.
            // Supply a short-lived ingest credential at runtime when testing a real backend.
            let token = environment["PROXYCEPT_INGEST_TOKEN"] ?? "plog_ingest_demo_only"
            logger = try ProxyceptLogger(configuration: LoggingConfiguration(
                baseURL: URL(string: "http://127.0.0.1:18880")!, ingestToken: token,
                appVersion: "1.0", build: "1", spoolDirectory: directory))
            startupError = nil
        } catch {
            logger = nil
            startupError = String(describing: error)
        }
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 20) {
                Text("Proxycept Logging").font(.title)
                Text(status).accessibilityIdentifier("delivery-status")
                Button("Emit loopback event") { Task { await emit() } }
            }
            .padding()
            .task { await emit() }
            .onChange(of: scenePhase) { phase in
                logger?.setForegroundActive(phase == .active)
            }
        }
    }

    @MainActor private func emit() async {
        guard let logger else { status = startupError ?? "Unavailable"; return }
        logger.log(level: .info, category: "ios-demo", message: "Demo tapped password=do-not-store",
                   attributes: ["screen": .string("home"), "authorization": .string("do-not-store")],
                   correlationId: "demo-\(UUID().uuidString)")
        await logger.flush()
        let stats = await logger.deliveryStats()
        status = "Accepted: \(stats.accepted), queued: \(stats.queued), failures: \(stats.failures)"
    }
}
