package com.proxycept.loggingflutter

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.system.Os
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

class ProxyceptLoggingPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private val main = Handler(Looper.getMainLooper())
    private val io = ThreadPoolExecutor(1, 1, 0L, TimeUnit.SECONDS, ArrayBlockingQueue(32))
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "com.proxycept.logging/private_spool")
        channel.setMethodCallHandler(this)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "prepareSpool" && call.method != "verifySpool") { result.notImplemented(); return }
        val namespace = call.argument<String>("namespace")
        if (namespace == null || !namespace.matches(Regex("^[A-Za-z0-9_-]{1,64}$"))) {
            result.error("invalid", "Invalid spool namespace", null); return
        }
        try {
            io.execute {
                try {
                    val base = context.noBackupFilesDir.canonicalFile
                    val folder = File(base, "proxycept-logs-$namespace")
                    if (call.method == "prepareSpool" && !folder.exists() && !folder.mkdir()) throw IllegalStateException()
                    if (!folder.isDirectory || folder.canonicalFile.parentFile != base ||
                        folder.absolutePath != folder.canonicalPath) throw IllegalStateException()
                    if (call.method == "prepareSpool") Os.chmod(folder.path, 448) // 0700; never repair during verification.
                    if (call.method == "verifySpool") {
                        val queue = File(folder, "queue.json")
                        val details = mapOf("backupExcluded" to (folder.canonicalFile.parentFile == base),
                            "directoryPrivate" to ((Os.stat(folder.path).st_mode and 511) == 448),
                            "fileProtected" to ((Os.stat(queue.path).st_mode and 511) == 384),
                            "platform" to "android")
                        main.post { result.success(details) }
                    } else { main.post { result.success(folder.canonicalPath) } }
                } catch (_: Exception) { main.post { result.error("storage", "Protected private storage unavailable", null) } }
            }
        } catch (_: Exception) { result.error("storage", "Storage worker unavailable", null) }
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        io.shutdown()
    }
}
