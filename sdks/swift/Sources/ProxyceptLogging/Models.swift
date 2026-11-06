import Foundation

public enum LogLevel: String, Codable, Sendable { case debug, info, warning, error }

/// Wire attributes deliberately accept scalars only. Non-finite numbers are rejected.
public enum LogValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else { self = .string(try value.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .bool(let bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

public enum LoggingError: Error, Equatable {
    case invalidURL, invalidToken, invalidMetadata, invalidLimits, spoolInUse
}

public struct LoggingConfiguration: Sendable {
    public let baseURL: URL
    public let ingestToken: String
    public var appVersion: String
    public var build: String
    /// Omit to use a random installation identifier retained in this spool.
    public var installationId: String?
    /// Omit to generate a fresh debug session for this client instance.
    public var debugSessionId: String
    /// A dedicated directory, owned exclusively by this client. Never put credentials here.
    public var spoolDirectory: URL
    public var maxEvents: Int = 2_000
    public var maxBytes: Int = 2 * 1_024 * 1_024
    public var redaction: RedactionPolicy = .init()

    public init(baseURL: URL, ingestToken: String, appVersion: String, build: String,
                installationId: String? = nil, debugSessionId: String = UUID().uuidString,
                spoolDirectory: URL) {
        self.baseURL = baseURL
        self.ingestToken = ingestToken
        self.appVersion = appVersion
        self.build = build
        self.installationId = installationId
        self.debugSessionId = debugSessionId
        self.spoolDirectory = spoolDirectory
    }
}

public struct DeliveryStats: Sendable {
    public internal(set) var queued = 0
    public internal(set) var accepted = 0
    public internal(set) var duplicate = 0
    public internal(set) var droppedOldest = 0
    public internal(set) var admissionDropped = 0
    public internal(set) var expired = 0
    public internal(set) var invalid = 0
    public internal(set) var rejected = 0
    public internal(set) var failures = 0
    public internal(set) var storageFailures = 0
    public internal(set) var corruptSpools = 0
    public internal(set) var authenticationStopped = false
    public internal(set) var disabled = false
}

struct Event: Codable {
    let event_id: String
    let sequence: Int64
    let client_time: String
    let severity: LogLevel
    let category: String
    let message: String
    let attributes: [String: LogValue]
    let correlation_id: String?

    enum CodingKeys: String, CodingKey {
        case event_id, sequence, client_time, severity, category, message, attributes, correlation_id
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(event_id, forKey: .event_id)
        try c.encode(sequence, forKey: .sequence)
        try c.encode(client_time, forKey: .client_time)
        try c.encode(severity, forKey: .severity)
        try c.encode(category, forKey: .category)
        try c.encode(message, forKey: .message)
        try c.encode(attributes, forKey: .attributes)
        try c.encode(correlation_id, forKey: .correlation_id)
    }
}

struct Metadata: Codable, Equatable {
    let app_version: String
    let build: String
    let installation_id: String
    let debug_session_id: String
}

struct QueuedEvent: Codable {
    let event: Event
    let metadata: Metadata
    let enqueuedAt: Date
}

struct Spool: Codable {
    var version = 1
    var installationId: String
    var nextSequence: Int64
    var entries: [QueuedEvent]
}

struct Batch: Encodable {
    let schema_version = 1
    let app_version: String
    let build: String
    let installation_id: String
    let debug_session_id: String
    let events: [Event]
    init(metadata: Metadata, events: [Event]) {
        app_version = metadata.app_version
        build = metadata.build
        installation_id = metadata.installation_id
        debug_session_id = metadata.debug_session_id
        self.events = events
    }
}

struct Acknowledgement: Decodable {
    let accepted: Int
    let duplicate: Int
    let received_at: String
}
