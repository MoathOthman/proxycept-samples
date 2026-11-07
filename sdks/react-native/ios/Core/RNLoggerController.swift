import Foundation

struct RNConfiguration: Codable {
    let baseUrl: String
    let ingestToken: String
    let appVersion: String
    let build: String
    var spoolName: String = "default"
    var debugSessionId: String?
    var installationId: String?
    var maxQueueEvents: Int = 2000
    var maxQueueBytes: Int = 2 * 1024 * 1024

    func validate() throws {
        guard spoolName.range(of: #"\A[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) != nil,
              (8192...2 * 1024 * 1024).contains(maxQueueBytes) else { throw LoggingError.invalidLimits }
        guard let url = URL(string: baseUrl) else { throw LoggingError.invalidURL }
        _ = try ingestURL(url)
    }
}
struct RNLogInput: Decodable {
    let level: LogLevel
    let category: String
    let message: String
    let attributes: [String: LogValue]
    let correlationId: String?
}

/// All initialization/disk work is off the RN calling thread. This actor also supplies
/// a Foundation-only integration seam; the exported module is a thin adapter below it.
public actor RNLoggerController {
    private let root: URL
    private let transport: any LogTransport
    private var logger: ProxyceptLogger?
    private var invalidated = false
    private var terminalStats: String?
    public init(root: URL, transport: any LogTransport = URLSessionLogTransport()) {
        self.root = root; self.transport = transport
    }
    public func configure(_ json: String) throws {
        guard !invalidated, json.utf8.count <= 8192, logger == nil else { throw LoggingError.spoolInUse }
        var configuration = try JSONDecoder().decode(RNConfiguration.self, from: Data(json.utf8))
        try configuration.validate()
        // Configuration bytes and token remain only in memory.
        if configuration.debugSessionId == nil { configuration.debugSessionId = UUID().uuidString }
        var core = LoggingConfiguration(baseURL: URL(string: configuration.baseUrl)!, ingestToken: configuration.ingestToken,
            appVersion: configuration.appVersion, build: configuration.build,
            installationId: configuration.installationId, debugSessionId: configuration.debugSessionId!,
            spoolDirectory: root.appendingPathComponent(configuration.spoolName, isDirectory: true))
        core.maxEvents = configuration.maxQueueEvents; core.maxBytes = configuration.maxQueueBytes
        let logger = try ProxyceptLogger(configuration: core, transport: transport)
        logger.setForegroundActive(false)
        self.logger = logger; terminalStats = nil
    }
    public func log(_ json: String) throws -> Bool {
        guard !invalidated, json.utf8.count <= 65536, let logger else { return false }
        let event = try JSONDecoder().decode(RNLogInput.self, from: Data(json.utf8))
        return logger.log(level: event.level, category: event.category, message: event.message,
            attributes: event.attributes, correlationId: event.correlationId)
    }
    public func flush() async { await logger?.flush() }
    public func foreground(_ active: Bool) { logger?.setForegroundActive(active) }
    public func reconfigure(_ token: String) async throws {
        guard let logger else { throw LoggingError.invalidToken }
        try await logger.reconfigure(ingestToken: token)
    }
    public func disable() async { await logger?.disable() }
    public func invalidate() async { invalidated = true; await close() }
    public func close() async {
        guard let current = logger else { return }
        // Remove it before the await so a late bridge log cannot reuse a closed engine.
        logger = nil
        await current.close()
        terminalStats = Self.encode(await current.deliveryStats())
    }
    public func deliveryStats() async -> String {
        guard let logger else { return terminalStats ?? Self.encode(DeliveryStats()) }
        return Self.encode(await logger.deliveryStats())
    }
    private static func encode(_ stats: DeliveryStats) -> String {
        let object: [String: Any] = ["queued": stats.queued, "accepted": stats.accepted,
            "duplicate": stats.duplicate, "dropped": stats.droppedOldest + stats.invalid + stats.rejected + stats.admissionDropped,
            "expired": stats.expired, "failures": stats.failures, "storageFailures": stats.storageFailures,
            "authenticationStopped": stats.authenticationStopped, "disabled": stats.disabled]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
