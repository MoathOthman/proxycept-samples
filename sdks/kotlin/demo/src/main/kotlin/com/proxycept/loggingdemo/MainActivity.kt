package com.proxycept.loggingdemo

import android.app.Activity
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.proxycept.logging.Configuration
import com.proxycept.logging.Level
import com.proxycept.logging.ProxyceptLogger
import java.io.File

/** Explicit manual demo; no global hooks, device settings, or credentials in the APK. */
class MainActivity : Activity() {
    private var logger: ProxyceptLogger? = null
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var status: TextView
    private val refresh = object : Runnable {
        override fun run() {
            logger?.let { status.text = it.stats().toString() }
            handler.postDelayed(this, 1000)
        }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(24, 48, 24, 24) }
        status = TextView(this)
        layout.addView(status)
        try {
            val token = intent.getStringExtra("token") ?: error("Missing token")
            val base = intent.getStringExtra("baseUrl") ?: "http://127.0.0.1:18880"
            logger = ProxyceptLogger(Configuration(base, token, File(noBackupFilesDir, "proxycept-demo"), "1.0", "1"))
            // Do not retain token in the Activity's Intent beyond configuration.
            intent.removeExtra("token")
            fun send() {
                logger?.log(Level.INFO, "android-demo", "Android logging SDK smoke",
                    mapOf("screen" to "demo", "password" to "must-be-redacted", "email" to "qa@example.com"),
                    intent.getStringExtra("correlationId") ?: "android-demo-smoke")
                logger?.flush()
            }
            layout.addView(Button(this).apply { text = "Send event"; setOnClickListener { send() } })
            layout.addView(Button(this).apply { text = "Disable and clear"; setOnClickListener { logger?.disable() } })
            send()
            handler.post(refresh)
        } catch (_: Exception) {
            status.text = "Launch with token and optional baseUrl Intent extras; see SDK README."
        }
        setContentView(layout)
    }
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        val closing = logger
        logger = null
        // close() is a blocking durability barrier; never run it on the Activity/UI thread.
        if (closing != null) Thread({
            check(Looper.myLooper() != Looper.getMainLooper())
            closing.close()
        }, "proxycept-demo-close").start()
        super.onDestroy()
    }
}
