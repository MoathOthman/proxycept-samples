import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Thread-safe client. After synchronous initialization, queue and disk work run on
/// a private serial queue; async delivery runs off the calling thread.
/// Call close() before releasing your final reference. A single client owns each spool.
public final class ProxyceptLogger: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.proxycept.logging", qos: .utility)
    private let admissionLock = NSLock()
    private var pending = 0
    private var admissionDrops = 0
    private var invalidAdmissions = 0
    private let config: LoggingConfiguration
    private let endpoint: URL
    private var token: String
    private let transport: any LogTransport
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let encoder = JSONEncoder()
    private let file: URL
    private let lockFD: Int32
    private var spool: Spool
    private let metadata: Metadata
    private var stats = DeliveryStats()
    private var timer: DispatchSourceTimer?
    private var active = true
    private var inFlight = false
    private var generation = 0
    private var retryAt = Date.distantPast
    private var attempts = 0
    private var batchLimit = 50
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private static let lifetime: TimeInterval = 3 * 24 * 60 * 60

    public convenience init(configuration: LoggingConfiguration,
                            transport: any LogTransport = URLSessionLogTransport()) throws {
        try self.init(configuration: configuration, transport: transport,
                      now: { Date() }, jitter: { Double.random(in: 0...1) }, startTimer: true)
    }

    // Clock, random source and timer control are internal test seams; transport is public.
    init(configuration: LoggingConfiguration, transport: any LogTransport,
         now: @escaping @Sendable () -> Date, jitter: @escaping @Sendable () -> Double,
         startTimer: Bool) throws {
        endpoint = try ingestURL(configuration.baseURL)
        guard Self.validToken(configuration.ingestToken) else { throw LoggingError.invalidToken }
        guard (1...2_000).contains(configuration.maxEvents),
              (1_024...2 * 1_024 * 1_024).contains(configuration.maxBytes),
              configuration.spoolDirectory.isFileURL else { throw LoggingError.invalidLimits }
        guard Self.validMetadata(configuration.appVersion, limit: 80),
              Self.validMetadata(configuration.build, limit: 80),
              Self.validMetadata(configuration.debugSessionId, limit: 128),
              configuration.installationId.map({ Self.validMetadata($0, limit: 128) }) ?? true else {
            throw LoggingError.invalidMetadata
        }
        config = configuration
        token = configuration.ingestToken
        self.transport = transport
        self.now = now
        self.jitter = jitter
        file = configuration.spoolDirectory.appendingPathComponent("queue.json")
        let fm = FileManager.default
        if (try? configuration.spoolDirectory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try fm.createDirectory(at: configuration.spoolDirectory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try Self.protect(configuration.spoolDirectory, directory: true)
        let fd = open(configuration.spoolDirectory.appendingPathComponent("queue.lock").path,
                      O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Self.release(fd)
            throw LoggingError.spoolInUse
        }
        lockFD = fd
        var loaded: Spool?
        var corrupt = false
        var invalidStored = 0
        do {
            if fm.fileExists(atPath: file.path) {
                let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 2 * 1_024 * 1_024 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let data = try Data(contentsOf: file)
                var candidate = try JSONDecoder().decode(Spool.self, from: data)
                guard candidate.version == 1, Self.validMetadata(candidate.installationId, limit: 128),
                      candidate.nextSequence >= 0, candidate.entries.count <= 2_000,
                      Set(candidate.entries.map { $0.event.event_id }).count == candidate.entries.count,
                      candidate.entries.allSatisfy({ $0.event.sequence < candidate.nextSequence }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Individually invalid legacy events must not discard valid neighbors.
                let valid = candidate.entries.filter { Self.validStored($0, now: now()) }
                invalidStored = candidate.entries.count - valid.count
                candidate.entries = valid
                loaded = candidate
            }
        } catch {
            // Fail closed: never upload partially decoded or tampered data.
            corrupt = true
        }
        let installation = configuration.installationId ?? loaded?.installationId ?? UUID().uuidString
        let scrub: (String) -> String = { configuration.redaction.scrub($0, credential: configuration.ingestToken) }
        metadata = Metadata(app_version: limited(scrub(configuration.appVersion), to: 80), build: limited(scrub(configuration.build), to: 80),
                            installation_id: limited(scrub(installation), to: 128), debug_session_id: limited(scrub(configuration.debugSessionId), to: 128))
        spool = loaded ?? Spool(installationId: metadata.installation_id, nextSequence: 0, entries: [])
        spool.installationId = metadata.installation_id
        if corrupt { stats.corruptSpools += 1 }
        stats.invalid += invalidStored
        // Loading also expires and re-scrubs previously persisted data with today's policy.
        spool.entries = spool.entries.map { item in
            let e = item.event
            return QueuedEvent(event: Event(event_id: limited(scrub(e.event_id), to: 128), sequence: e.sequence, client_time: e.client_time,
                severity: e.severity, category: limited(scrub(e.category), to: 80), message: limited(scrub(e.message), to: 4_096),
                attributes: Self.scrubAttributes(e.attributes, policy: configuration.redaction, token: configuration.ingestToken),
                correlation_id: e.correlation_id.map { limited(scrub($0), to: 128) }),
                metadata: Metadata(app_version: limited(scrub(item.metadata.app_version), to: 80), build: limited(scrub(item.metadata.build), to: 80),
                    installation_id: limited(scrub(item.metadata.installation_id), to: 128), debug_session_id: limited(scrub(item.metadata.debug_session_id), to: 128)),
                enqueuedAt: item.enqueuedAt)
        }
        let validEntries = spool.entries.filter { Self.validStored($0, now: now()) }
        stats.invalid += spool.entries.count - validEntries.count
        spool.entries = validEntries
        expire()
        persist()
        if startTimer {
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 2, repeating: 2)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let previous = self.spool.entries.count
                self.expire()
                if previous != self.spool.entries.count { self.persist() }
                if self.active { self.deliver() }
            }
            timer = source
            source.resume()
        }
    }

    deinit { timer?.cancel(); Self.release(lockFD) }

    /// Returns false if input is invalid or the bounded admission buffer is full.
    /// True means scheduled locally, not durably written or delivered. Use deliveryStats().
    @discardableResult
    public func log(level: LogLevel, category: String, message: String,
                    attributes: [String: LogValue] = [:], correlationId: String? = nil) -> Bool {
        guard category.unicodeScalars.count <= 80, message.unicodeScalars.count <= 4_096, Self.validAttributes(attributes),
              correlationId.map({ $0.unicodeScalars.count <= 128 }) ?? true else {
            admissionLock.lock(); invalidAdmissions += 1; admissionLock.unlock()
            return false
        }
        admissionLock.lock()
        guard pending < 32 else { admissionDrops += 1; admissionLock.unlock(); return false }
        pending += 1
        admissionLock.unlock()
        queue.async { [self] in
            defer { admissionLock.lock(); pending -= 1; admissionLock.unlock() }
            guard !stats.disabled, spool.nextSequence < Int64.max else { stats.rejected += 1; return }
            expire()
            let clean: (String) -> String = { self.config.redaction.scrub($0, credential: self.token) }
            let timestamp = Self.timestamp(now())
            let event = Event(event_id: UUID().uuidString, sequence: spool.nextSequence,
                client_time: timestamp, severity: level, category: limited(clean(category), to: 80), message: limited(clean(message), to: 4_096),
                attributes: Self.scrubAttributes(attributes, policy: config.redaction, token: token),
                correlation_id: correlationId.map { limited(clean($0), to: 128) })
            guard Self.validAttributes(event.attributes),
                  let encoded = try? encoder.encode(event), encoded.count <= 8_192 else { stats.invalid += 1; return }
            spool.nextSequence += 1
            spool.entries.append(QueuedEvent(event: event, metadata: metadata, enqueuedAt: now()))
            persist()
        }
        return true
    }

    /// Attempts to drain queued batches, stopping at a failure/backoff/auth stop.
    /// Respects Retry-After and backoff even when invoked explicitly. Returns after this attempt.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                waiters.append(continuation)
                deliver()
            }
        }
    }

    /// Stops timers and admissions, waiting for an existing request. Undelivered data remains durable.
    /// Call flush() first if a final delivery attempt is desired.
    public func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stats.disabled = true
                timer?.cancel(); timer = nil
                continuation.resume()
            }
        }
        // close retains queued data and never initiates network after disabling.
        await waitForCurrentDelivery()
    }

    /// Disables future delivery. Purges the durable queue by default. A request already sent
    /// cannot be recalled; its completion is ignored. Create a new client to enable again.
    public func disable(purge: Bool = true) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                stats.disabled = true
                timer?.cancel(); timer = nil
                generation += 1
                if purge { spool.entries.removeAll(); persist() }
                finishWaiters()
                continuation.resume()
            }
        }
    }

    /// Rotates only the in-memory credential and clears an authentication stop/backoff.
    public func reconfigure(ingestToken: String) async throws {
        guard Self.validToken(ingestToken) else { throw LoggingError.invalidToken }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                generation += 1
                token = ingestToken
                stats.authenticationStopped = false
                attempts = 0; retryAt = .distantPast
                continuation.resume()
            }
        }
    }

    /// Drive from scenePhase/application lifecycle. Foreground automatic delivery is every 2s.
    /// Explicit flush remains available in the background; the host owns background time.
    public func setForegroundActive(_ active: Bool) {
        queue.async { [self] in self.active = active }
    }

    public func deliveryStats() async -> DeliveryStats {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                expire(); persist()
                var result = stats
                result.queued = spool.entries.count
                admissionLock.lock()
                result.invalid += invalidAdmissions
                result.admissionDropped = admissionDrops
                admissionLock.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    private func waitForCurrentDelivery() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if inFlight { waiters.append(continuation) } else { continuation.resume() }
            }
        }
    }

    private func deliver() {
        guard !inFlight else { return }
        let previous = spool.entries.count
        expire()
        if previous != spool.entries.count { persist() }
        guard !stats.disabled, !stats.authenticationStopped, now() >= retryAt, let first = spool.entries.first else {
            finishWaiters(); return
        }
        var items = Array(spool.entries.prefix(batchLimit).prefix { $0.metadata == first.metadata })
        var body: Data
        while true {
            guard let encoded = try? encoder.encode(Batch(metadata: first.metadata, events: items.map(\.event))) else {
                stats.invalid += items.count; spool.entries.removeFirst(items.count); persist(); finishWaiters(); return
            }
            if encoded.count <= 256 * 1_024 { body = encoded; break }
            items.removeLast()
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 15
        let ids = Set(items.map { $0.event.event_id })
        let count = items.count
        let revision = generation
        inFlight = true
        Task { [self, request] in
            let result: Result<TransportResponse, Error>
            do { result = .success(try await transport.send(request)) }
            catch { result = .failure(error) }
            queue.async { [self] in
                inFlight = false
                guard revision == generation else { finishWaiters(); return }
                handle(result, ids: ids, count: count)
            }
        }
    }

    private func handle(_ result: Result<TransportResponse, Error>, ids: Set<String>, count: Int) {
        switch result {
        case .failure: backoff()
        case .success(let response):
            switch response.statusCode {
            case 200:
                guard let ack = try? JSONDecoder().decode(Acknowledgement.self, from: response.body),
                      ack.accepted >= 0, ack.duplicate >= 0, ack.accepted <= count,
                      ack.duplicate == count - ack.accepted, Self.parseTimestamp(ack.received_at) != nil else {
                    backoff(); finishWaiters(); return
                }
                stats.accepted += ack.accepted; stats.duplicate += ack.duplicate
                spool.entries.removeAll { ids.contains($0.event.event_id) }
                attempts = 0; retryAt = .distantPast
                persist(); deliver(); return
            case 401, 403:
                stats.authenticationStopped = true; stats.failures += 1
            case 413:
                stats.failures += 1
                if count > 1 { batchLimit = max(1, count / 2); deliver(); return }
                spool.entries.removeAll { ids.contains($0.event.event_id) }
                stats.rejected += count; persist(); deliver(); return
            case 429:
                let header = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
                backoff(minimum: header.flatMap(retryDelay) ?? 0)
            case 408, 500...599: backoff()
            default:
                // Permanent 4xx/redirect/protocol errors discard the atomic batch.
                spool.entries.removeAll { ids.contains($0.event.event_id) }
                stats.rejected += count; persist()
            }
        }
        finishWaiters()
    }

    private func backoff(minimum: TimeInterval = 0) {
        stats.failures += 1
        attempts = min(10, attempts + 1)
        let delay = min(300, pow(2, Double(attempts))) * (0.5 + min(1, max(0, jitter())))
        retryAt = now().addingTimeInterval(max(delay, minimum))
    }

    private func retryDelay(_ value: String) -> TimeInterval? {
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now())) }
    }

    private func finishWaiters() {
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func expire() {
        let before = spool.entries.count
        spool.entries.removeAll { now().timeIntervalSince($0.enqueuedAt) >= Self.lifetime }
        stats.expired += before - spool.entries.count
    }

    private func persist() {
        if spool.entries.count > config.maxEvents {
            let count = spool.entries.count - config.maxEvents
            spool.entries.removeFirst(count); stats.droppedOldest += count
        }
        do {
            var data = try encoder.encode(spool)
            while data.count > config.maxBytes, !spool.entries.isEmpty {
                let count = max(1, spool.entries.count / 10)
                spool.entries.removeFirst(count); stats.droppedOldest += count
                data = try encoder.encode(spool)
            }
            guard data.count <= config.maxBytes else { throw CocoaError(.fileWriteOutOfSpace) }
            #if os(iOS) || os(tvOS) || os(watchOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try Self.protect(file, directory: false)
        } catch { stats.storageFailures += 1 }
    }

    private static func protect(_ url: URL, directory: Bool) throws {
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: directory ? 0o700 : 0o600]
        #if os(iOS) || os(tvOS) || os(watchOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }

    private static func release(_ fd: Int32) {
        _ = flock(fd, LOCK_UN)
        #if canImport(Darwin)
        _ = Darwin.close(fd)
        #else
        _ = Glibc.close(fd)
        #endif
    }

    private static func validToken(_ value: String) -> Bool {
        value.hasPrefix("plog_ingest_") && value.count > 12 && value.unicodeScalars.count <= 512 &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private static func validMetadata(_ value: String, limit: Int) -> Bool { !value.isEmpty && value.unicodeScalars.count <= limit }
    private static func validAttributes(_ attributes: [String: LogValue]) -> Bool {
        attributes.count <= 16 && attributes.allSatisfy {
            !$0.key.isEmpty && $0.key.unicodeScalars.count <= 64 && validValue($0.value)
        }
    }
    private static func validValue(_ value: LogValue) -> Bool {
        switch value {
        case .string(let string): return string.unicodeScalars.count <= 512
        case .number(let number): return number.isFinite && abs(number) <= 1e308
        default: return true
        }
    }
    private static func scrubAttributes(_ attributes: [String: LogValue], policy: RedactionPolicy,
                                        token: String) -> [String: LogValue] {
        var result: [String: LogValue] = [:]
        for key in attributes.keys.sorted() {
            let cleanKey = limited(policy.scrub(key, credential: token), to: 64)
            if policy.isSensitive(key) { result[cleanKey] = .string("[REDACTED]") }
            else if case .string(let value) = attributes[key] {
                result[cleanKey] = .string(limited(policy.scrub(value, credential: token), to: 512))
            } else { result[cleanKey] = attributes[key] }
        }
        return result
    }
    private static func validStored(_ item: QueuedEvent, now: Date) -> Bool {
        let e = item.event, m = item.metadata
        return validMetadata(e.event_id, limit: 128) && e.sequence >= 0 &&
            parseTimestamp(e.client_time) != nil && e.category.unicodeScalars.count <= 80 && e.message.unicodeScalars.count <= 4_096 &&
            validAttributes(e.attributes) &&
            (e.correlation_id.map { $0.unicodeScalars.count <= 128 } ?? true) &&
            validMetadata(m.app_version, limit: 80) && validMetadata(m.build, limit: 80) &&
            validMetadata(m.installation_id, limit: 128) && validMetadata(m.debug_session_id, limit: 128) &&
            item.enqueuedAt <= now.addingTimeInterval(300) &&
            ((try? JSONEncoder().encode(e).count).map { $0 <= 8_192 } ?? false)
    }
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
