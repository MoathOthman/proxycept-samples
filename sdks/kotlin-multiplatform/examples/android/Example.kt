package example

import android.content.Context
import com.proxycept.logging.kmp.*
import java.io.File

// API 26+. Call factory from your lifecycle/I/O coroutine; log() is safe on the UI thread.
fun androidLogger(context: Context, baseUrl: String, runtimeIngestKey: String): ProxyceptLogger =
    LoggingSdk.create(baseUrl, runtimeIngestKey,
        File(context.noBackupFilesDir, "proxycept-kmp-myapp-dev").absolutePath, "1.0", "12")
