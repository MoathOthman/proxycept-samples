import Foundation
import React
import UIKit

@objc(ProxyceptLogging)
final class ProxyceptLogging: NSObject, RCTInvalidating {
    private let controller: RNLoggerController
    private let lock = NSLock()
    private var pending = 0
    private var invalidated = false
    private var observers: [NSObjectProtocol] = []
    override init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProxyceptReactNative", isDirectory: true)
        controller = RNLoggerController(root: root)
        super.init()
        for notification in [UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) {
                [weak self] _ in self?.setForegroundActive(UIApplication.shared.applicationState == .active)
            })
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    @objc static func requiresMainQueueSetup() -> Bool { false }

    private func perform(_ resolve: @escaping RCTPromiseResolveBlock, _ reject: @escaping RCTPromiseRejectBlock,
                         operation: @escaping (RNLoggerController) async throws -> Any?) {
        lock.lock()
        guard !invalidated, pending < 32 else { lock.unlock(); reject("E_BUSY", "Logging worker unavailable", nil); return }
        pending += 1; lock.unlock()
        Task {
            defer { finishAdmission() }
            do { resolve(try await operation(controller)) }
            catch { reject("E_LOGGING", "Native logging operation failed", nil) }
        }
    }
    private func finishAdmission() { lock.lock(); pending -= 1; lock.unlock() }
    @objc(configure:resolver:rejecter:)
    func configure(_ json: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard json.utf8.count <= 8192 else { reject("E_CONFIGURATION", "Invalid logging configuration", nil); return }
        perform(resolve, reject) { controller in try await controller.configure(json); return nil }
    }
    @objc(log:resolver:rejecter:)
    func log(_ json: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard json.utf8.count <= 65536 else { resolve(false); return }
        perform(resolve, reject) { controller in (try? await controller.log(json)) ?? false }
    }
    @objc(flush:rejecter:)
    func flush(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { controller in await controller.flush(); return nil }
    }
    @objc(deliveryStats:rejecter:)
    func deliveryStats(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { controller in await controller.deliveryStats() }
    }
    @objc(reconfigure:resolver:rejecter:)
    func reconfigure(_ token: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard token.utf8.count <= 512 else { reject("E_CONFIGURATION", "Invalid ingest token", nil); return }
        perform(resolve, reject) { controller in try await controller.reconfigure(token); return nil }
    }
    @objc func setForegroundActive(_ active: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let effective = active && UIApplication.shared.applicationState == .active
            Task { await self.controller.foreground(effective) }
        }
    }
    @objc(disable:rejecter:)
    func disable(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { controller in await controller.disable(); return nil }
    }
    @objc(close:rejecter:)
    func close(_ resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        perform(resolve, reject) { controller in await controller.close(); return nil }
    }
    func invalidate() {
        lock.lock(); invalidated = true; lock.unlock()
        Task { await controller.invalidate() }
    }
}
