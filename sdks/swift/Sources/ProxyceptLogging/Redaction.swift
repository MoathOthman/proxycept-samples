import Foundation

/// Best-effort scrubbing, not a guarantee of PII removal. Never log secrets intentionally.
public struct RedactionPolicy: Sendable {
    public var sensitiveKeys: Set<String>
    public var additionalPatterns: [String]

    public init(sensitiveKeys: Set<String> = ["authorization", "cookie", "set-cookie", "password",
                "passwd", "secret", "token", "api_key", "apikey", "access_token", "refresh_token"],
                additionalPatterns: [String] = []) {
        self.sensitiveKeys = sensitiveKeys
        self.additionalPatterns = additionalPatterns
    }

    func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return sensitiveKeys.contains { normalized.contains($0.lowercased().replacingOccurrences(of: "-", with: "_")) }
    }

    func scrub(_ input: String, credential: String) -> String {
        var result = input.replacingOccurrences(of: credential, with: "[REDACTED]")
        let patterns = [
            #"(?i)\bBearer\s+[^\s\"',;]+"#,
            #"\bplog_ingest_[A-Za-z0-9_-]+"#,
            #"(?i)(?:password|passwd|secret|token|api[_-]?key|authorization|cookie)\s*[=:]\s*(?:\"[^\"]*\"|'[^']*'|[^\s&,;]+)"#,
            #"\b[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        ] + additionalPatterns
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: "[REDACTED]")
        }
        return result
    }
}

func limited(_ value: String, to limit: Int) -> String {
    String(String.UnicodeScalarView(value.unicodeScalars.prefix(limit)))
}
