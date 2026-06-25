import SwiftUI
import Security

// Defaults for the local demo. The proxy host/port come from the Proxycept profile's
// Connection tab (or `POST /api/profiles/{id}/start`). 127.0.0.1 inside the iOS Simulator
// is the host Mac's loopback, so it reaches a locally-running proxy worker.
private let kDefaultProxyHost = "127.0.0.1"
private let kDefaultProxyPort = 19345
private let kDefaultTargetURL = "https://example.com"

struct Result: Identifiable {
    let id = UUID()
    let statusLine: String
    let tlsIssuer: String
    let bodyPreview: String
    let intercepted: Bool
}

@MainActor
final class DemoModel: NSObject, ObservableObject, URLSessionDelegate {
    @Published var proxyHost = kDefaultProxyHost
    @Published var proxyPort = String(kDefaultProxyPort)
    @Published var target = kDefaultTargetURL
    @Published var loading = false
    @Published var result: Result?
    @Published var error: String?

    // Captured from the TLS handshake so the UI can show *who signed the cert* —
    // if traffic is intercepted, example.com's leaf is signed by "Proxy Control CA".
    private var lastIssuer = "(unknown)"

    func fetch() {
        guard let url = URL(string: target), let port = Int(proxyPort) else {
            error = "Bad URL or port"; return
        }
        loading = true; error = nil; result = nil; lastIssuer = "(unknown)"

        let config = URLSessionConfiguration.ephemeral
        // Route everything through the Proxycept proxy. HTTPS is tunneled via CONNECT;
        // the string keys cover the HTTPS case on iOS (no kCF* HTTPS constants there).
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: proxyHost,
            kCFNetworkProxiesHTTPPort as String: port,
            "HTTPSEnable": 1,
            "HTTPSProxy": proxyHost,
            "HTTPSPort": port,
        ]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: url) { [weak self] data, response, err in
            Task { @MainActor in
                guard let self else { return }
                self.loading = false
                if let err {
                    self.error = err.localizedDescription
                    return
                }
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? -1
                let preview = String(data: (data ?? Data()).prefix(180), encoding: .utf8) ?? "(binary)"
                let intercepted = self.lastIssuer.contains("Proxy Control CA")
                self.result = Result(
                    statusLine: "HTTP \(status)  ·  \(url.host ?? "")",
                    tlsIssuer: self.lastIssuer,
                    bodyPreview: preview.trimmingCharacters(in: .whitespacesAndNewlines),
                    intercepted: intercepted
                )
            }
        }
        task.resume()
    }

    // Read the server cert's issuer, then let the system validate (the Proxycept CA is
    // installed as a trusted root in the simulator, so MITM'd TLS validates cleanly).
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if let trust = challenge.protectionSpace.serverTrust,
           let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
           let leaf = chain.first {
            let summary = (SecCertificateCopySubjectSummary(leaf) as String?) ?? "?"
            // The leaf summary is the host; to expose the signer we inspect the next cert.
            let issuer = chain.count > 1
                ? ((SecCertificateCopySubjectSummary(chain[1]) as String?) ?? summary)
                : summary
            Task { @MainActor in self.lastIssuer = issuer }
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

struct ContentView: View {
    @StateObject private var model = DemoModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Proxycept proxy") {
                    TextField("Host", text: $model.proxyHost).autocorrectionDisabled()
                    TextField("Port", text: $model.proxyPort).keyboardType(.numberPad)
                }
                Section("Request") {
                    TextField("URL", text: $model.target).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button(action: { model.fetch() }) {
                        HStack {
                            Image(systemName: "arrow.up.arrow.down.circle.fill")
                            Text("Fetch through Proxycept")
                        }
                    }.disabled(model.loading)
                }
                if model.loading { ProgressView("Requesting…") }
                if let e = model.error {
                    Section("Error") { Text(e).foregroundStyle(.red) }
                }
                if let r = model.result {
                    Section("Response") {
                        Text(r.statusLine).font(.headline)
                        Label(
                            r.intercepted ? "Intercepted by Proxycept" : "Not intercepted",
                            systemImage: r.intercepted ? "checkmark.seal.fill" : "xmark.seal"
                        ).foregroundStyle(r.intercepted ? .green : .orange)
                        Text("TLS cert issued by: \(r.tlsIssuer)").font(.footnote).foregroundStyle(.secondary)
                        Text(r.bodyPreview).font(.system(.caption, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Proxycept iOS Demo")
            .onAppear { model.fetch() }
        }
    }
}

@main
struct ProxyceptDemoApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
