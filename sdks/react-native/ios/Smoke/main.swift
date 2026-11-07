import Foundation
import ProxyceptRNCore
#if canImport(Darwin)
import Darwin
#endif

@main struct Smoke {
    static func main() async {
        do {
            let env = ProcessInfo.processInfo.environment
            guard let base = env["PROXYCEPT_TEST_BASE_URL"], let token = env["PROXYCEPT_TEST_INGEST_KEY"],
                  let session = env["PROXYCEPT_TEST_DEBUG_SESSION"], let path = env["PROXYCEPT_TEST_SPOOL_DIR"],
                  base.hasPrefix("http://127.0.0.1:"), !path.isEmpty, path.hasPrefix("/"), !session.isEmpty else {
                throw NSError(domain: "Smoke", code: 1)
            }
            // The root is operator-selected and must be private. Config still cannot choose arbitrary files.
            let controller = RNLoggerController(root: URL(fileURLWithPath: path, isDirectory: true))
            let config: [String: Any] = ["baseUrl": base, "ingestToken": token, "appVersion": "rn-smoke", "build": "1",
                "debugSessionId": session, "spoolName": "rn-integration", "maxQueueEvents": 2000, "maxQueueBytes": 2097152]
            try await controller.configure(String(decoding: JSONSerialization.data(withJSONObject: config), as: UTF8.self))
            let event = #"{"level":"info","category":"rn-integration","message":"Cross-platform SDK smoke","attributes":{"password":"must-be-redacted"},"correlationId":null}"#
            guard try await controller.log(event) else { throw NSError(domain: "Smoke", code: 2) }
            await controller.flush()
            let stats = try JSONSerialization.jsonObject(with: Data(await controller.deliveryStats().utf8)) as! [String: Any]
            await controller.close()
            guard (stats["queued"] as? Int) == 0, (stats["dropped"] as? Int) == 0, (stats["accepted"] as? Int ?? 0) + (stats["duplicate"] as? Int ?? 0) > 0 else {
                throw NSError(domain: "Smoke", code: 3)
            }
            print("PASS React Native native-core/controller smoke: committed acknowledgement and drained queue")
        } catch {
            // Never interpolate error/config/server body; it could contain credentials.
            fputs("FAIL React Native native-core/controller smoke\n", stderr)
            exit(1)
        }
    }
}
