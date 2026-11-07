import Flutter
import Foundation

public final class ProxyceptLoggingPlugin: NSObject, FlutterPlugin {
    private let io = DispatchQueue(label: "com.proxycept.logging.private-spool", qos: .utility)

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.proxycept.logging/private_spool", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(ProxyceptLoggingPlugin(), channel: channel)
    }

    private static func protectionName(_ attributes: [FileAttributeKey: Any]) -> String {
        let raw: String?
        if let typed = attributes[.protectionKey] as? FileProtectionType {
            raw = typed.rawValue
        } else {
            raw = attributes[.protectionKey] as? String
        }
        let known = [FileProtectionType.complete.rawValue, FileProtectionType.completeUnlessOpen.rawValue,
                     FileProtectionType.completeUntilFirstUserAuthentication.rawValue, FileProtectionType.none.rawValue]
        return raw.flatMap { known.contains($0) ? $0 : nil } ?? "unreported"
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "prepareSpool" || call.method == "verifySpool" else {
            result(FlutterMethodNotImplemented); return
        }
        guard let args = call.arguments as? [String: Any], let namespace = args["namespace"] as? String,
              (1...64).contains(namespace.utf8.count),
              namespace.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            result(FlutterError(code: "invalid", message: "Invalid spool namespace", details: nil)); return
        }
        io.async {
            do {
                let fm = FileManager.default
                let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                var folder = base.appendingPathComponent("ProxyceptLogs-" + namespace, isDirectory: true)
                if (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw CocoaError(.fileWriteNoPermission)
                }
                if call.method == "prepareSpool" {
                    try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
                        .posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    try fm.setAttributes([.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
                    var values = URLResourceValues(); values.isExcludedFromBackup = true
                    try folder.setResourceValues(values)
                    for file in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
                        if (try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                            throw CocoaError(.fileWriteNoPermission)
                        }
                        try fm.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                    }
                    let path = folder.resolvingSymlinksInPath().path
                    DispatchQueue.main.async { result(path) }
                } else {
                    // Read-only: never repair policy while measuring it.
                    let attributes = try fm.attributesOfItem(atPath: folder.appendingPathComponent("queue.json").path)
                    let directoryAttributes = try fm.attributesOfItem(atPath: folder.path)
                    let protection = Self.protectionName(attributes)
                    let filePrivate = (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
                    #if targetEnvironment(simulator)
                    let simulator = true
                    #else
                    let simulator = false
                    #endif
                    let details: [String: Any] = [
                        "backupExcluded": try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true,
                        "directoryPrivate": (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700,
                        "filePrivate": filePrivate,
                        "fileProtected": filePrivate && protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue,
                        "protectionClass": protection,
                        "directoryProtectionClass": Self.protectionName(directoryAttributes),
                        "isSimulator": simulator,
                        "platform": "ios"]
                    DispatchQueue.main.async { result(details) }
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "storage", message: "Protected private storage unavailable", details: nil))
                }
            }
        }
    }
}
