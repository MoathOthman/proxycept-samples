package com.proxycept.loggingdemo

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import com.proxycept.logging.Configuration
import com.proxycept.logging.Level
import com.proxycept.logging.ProxyceptLogger
import com.proxycept.logging.Transport
import com.proxycept.logging.UrlConnectionTransport
import java.io.File
import java.util.UUID

/** Run by main/device owner only. Uses a unique app-private spool, removed after the test. */
class SmokeInstrumentation : Instrumentation() {
    private lateinit var arguments: Bundle
    override fun onCreate(arguments: Bundle?) {
        this.arguments = arguments ?: Bundle()
        start()
    }
    override fun onStart() {
        val result = Bundle()
        val directory = File(targetContext.noBackupFilesDir, "instrumentation-${UUID.randomUUID()}")
        try {
            val token = arguments.getString("token") ?: error("Missing -e token")
            val baseUrl = arguments.getString("baseUrl") ?: "http://127.0.0.1:18880"
            val correlation = arguments.getString("correlationId") ?: "android-instrumentation-smoke"
            val platformTransport = UrlConnectionTransport()
            val verifyingTransport = Transport { endpoint, key, body ->
                // Transport may only run after successful worker persistence, so verify at that boundary.
                val disk = File(directory, "queue.jsonl").readText()
                check(disk.contains("Android SDK instrumentation smoke"))
                check(!disk.contains(token) && !disk.contains("must-be-redacted"))
                platformTransport.post(endpoint, key, body)
            }
            ProxyceptLogger(Configuration(baseUrl, token, directory, "1.0", "1"), verifyingTransport).use { logger ->
                check(logger.log(Level.INFO, "android-instrumentation", "Android SDK instrumentation smoke",
                    mapOf("password" to "must-be-redacted", "screen" to "instrumentation"), correlation))
                logger.flush()
                val deadline = System.currentTimeMillis() + 15_000
                while (logger.stats().accepted + logger.stats().duplicates == 0L && System.currentTimeMillis() < deadline) {
                    Thread.sleep(100)
                }
                check(logger.stats().accepted + logger.stats().duplicates == 1L) { logger.stats().toString() }
                result.putString("proxycept_result", "PASS: ${logger.stats()}")
            }
            finish(Activity.RESULT_OK, result)
        } catch (error: Exception) {
            result.putString("proxycept_result", "FAIL: ${error.javaClass.simpleName}")
            finish(Activity.RESULT_CANCELED, result)
        } finally { directory.deleteRecursively() }
    }
}
