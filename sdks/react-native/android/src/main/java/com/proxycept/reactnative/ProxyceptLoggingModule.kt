package com.proxycept.reactnative

import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.LifecycleEventListener
import com.facebook.react.common.LifecycleState
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.proxycept.reactnative.core.RNLoggerController
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException

class ProxyceptLoggingModule(private val context: ReactApplicationContext) : ReactContextBaseJavaModule(context), LifecycleEventListener {
    // Bounded even if a caller bypasses the JS facade. No bridge method does I/O.
    private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(32),
        { task -> Thread(task, "proxycept-rn-bridge").apply { isDaemon = true } })
    private val controller = RNLoggerController(File(context.noBackupFilesDir, "proxycept-react-native"))
    @Volatile private var invalidated = false
    @Volatile private var hostActive = context.lifecycleState == LifecycleState.RESUMED
    init { context.addLifecycleEventListener(this) }
    override fun getName() = "ProxyceptLogging"
    private fun perform(promise: Promise, operation: () -> Any?) {
        try { worker.execute {
            try {
                check(!invalidated)
                promise.resolve(operation())
            } catch (_: Exception) { promise.reject("E_LOGGING", "Native logging operation failed") }
            finally { if (invalidated) controller.close() }
        } } catch (_: RejectedExecutionException) { promise.reject("E_BUSY", "Logging worker unavailable") }
    }
    @ReactMethod fun configure(json: String, promise: Promise) {
        if (json.length > 8192 || json.toByteArray(Charsets.UTF_8).size > 8192) {
            promise.reject("E_CONFIGURATION", "Invalid logging configuration"); return
        }
        perform(promise) { controller.configure(json); null }
    }
    @ReactMethod fun log(json: String, promise: Promise) {
        if (json.length > 65536 || json.toByteArray(Charsets.UTF_8).size > 65536) { promise.resolve(false); return }
        perform(promise) { controller.log(json) }
    }
    @ReactMethod fun flush(promise: Promise) = perform(promise) { controller.flush(); null }
    @ReactMethod fun deliveryStats(promise: Promise) = perform(promise) { controller.deliveryStats() }
    @ReactMethod fun reconfigure(token: String, promise: Promise) {
        if (token.length > 512) { promise.reject("E_CONFIGURATION", "Invalid ingest token"); return }
        perform(promise) { controller.reconfigure(token); null }
    }
    @ReactMethod fun disable(promise: Promise) = perform(promise) { controller.disable(); null }
    @ReactMethod fun close(promise: Promise) = perform(promise) { controller.close(); null }
    @ReactMethod fun setForegroundActive(active: Boolean) { controller.foreground(active && hostActive && !invalidated) }
    override fun onHostResume() { hostActive = true; controller.foreground(!invalidated) }
    override fun onHostPause() { hostActive = false; controller.foreground(false) }
    override fun onHostDestroy() { hostActive = false; controller.foreground(false) }
    override fun invalidate() {
        invalidated = true; controller.foreground(false); context.removeLifecycleEventListener(this)
        try { worker.execute { controller.close() } } catch (_: RejectedExecutionException) { /* already stopped */ }
        worker.shutdown()
        super.invalidate()
    }
}
