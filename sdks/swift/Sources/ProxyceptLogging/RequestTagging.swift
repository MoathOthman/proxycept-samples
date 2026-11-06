import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Opt-in request tagging. Nothing here runs unless the app calls it on a request it builds:
/// there is no URLProtocol, swizzling or global interception.
extension ProxyceptLogger {
    /// Header Proxycept reads to link a captured request to app logs with the same `correlationId`.
    public static let correlationHeader = "X-Proxycept-Correlation-ID"

    /// Sets `X-Proxycept-Correlation-ID` on `request` and returns the value, for use as the
    /// `correlationId` of related `log(...)` calls.
    ///
    /// - With an explicit valid `correlationId`, that value is used.
    /// - Otherwise an existing valid header value on the request is reused.
    /// - Otherwise a fresh UUID string is generated.
    ///
    /// Never traps or throws. An invalid explicit ID (or invalid existing header) is not sent;
    /// a fresh UUID replaces it, so always log with the returned value. Valid IDs are
    /// 1–128 visible ASCII characters (no spaces, control characters, CR or LF).
    ///
    /// Only tag requests to endpoints your app controls. Do not tag signed requests (for
    /// example AWS SigV4 or HMAC-signed) or third-party requests: an added header can break
    /// their signature or leak an identifier to another party.
    @discardableResult
    public static func tag(_ request: inout URLRequest, correlationId: String? = nil) -> String {
        let id: String
        if let explicit = correlationId, isValidCorrelationId(explicit) {
            id = explicit
        } else if correlationId == nil, let existing = request.value(forHTTPHeaderField: correlationHeader),
                  isValidCorrelationId(existing) {
            id = existing
        } else {
            id = UUID().uuidString
        }
        request.setValue(id, forHTTPHeaderField: correlationHeader)
        return id
    }

    /// True when `value` can be sent as a correlation header and accepted by `log(correlationId:)`.
    public static func isValidCorrelationId(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= 128 &&
            value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
