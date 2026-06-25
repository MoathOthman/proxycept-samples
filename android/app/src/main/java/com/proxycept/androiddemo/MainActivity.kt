package com.proxycept.androiddemo

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import javax.net.ssl.HttpsURLConnection
import java.security.cert.X509Certificate

// In the Android emulator, the host machine's loopback is 10.0.2.2 (not 127.0.0.1).
// Point these at your Proxycept proxy (the profile's Connection tab gives host/port).
private const val DEFAULT_PROXY_HOST = "10.0.2.2"
private const val DEFAULT_PROXY_PORT = "19345"
private const val DEFAULT_TARGET = "https://example.com"

data class FetchResult(
    val statusLine: String,
    val tlsIssuer: String,
    val intercepted: Boolean,
    val bodyPreview: String,
)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { MaterialTheme { DemoScreen(::fetch) } }
    }

    /** Run the request through the proxy and read the TLS issuer off the connection. */
    private fun fetch(
        host: String,
        port: Int,
        target: String,
        onResult: (Result<FetchResult>) -> Unit,
    ) {
        lifecycleScope.launch {
            val r = withContext(Dispatchers.IO) {
                runCatching {
                    val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress(host, port))
                    val conn = URL(target).openConnection(proxy) as HttpsURLConnection
                    conn.connectTimeout = 15000
                    conn.readTimeout = 15000
                    conn.connect()
                    val status = conn.responseCode
                    // The server cert the app sees: if intercepted, it's signed by the proxy CA.
                    val leaf = conn.serverCertificates.firstOrNull() as? X509Certificate
                    val issuer = leaf?.issuerX500Principal?.name ?: "(unknown)"
                    val body = conn.inputStream.bufferedReader().use { it.readText() }
                    conn.disconnect()
                    FetchResult(
                        statusLine = "HTTP $status  ·  ${URL(target).host}",
                        tlsIssuer = issuer,
                        intercepted = issuer.contains("Proxy Control CA"),
                        bodyPreview = body.take(180).trim(),
                    )
                }
            }
            onResult(r)
        }
    }
}

@Composable
fun DemoScreen(
    fetch: (String, Int, String, (Result<FetchResult>) -> Unit) -> Unit,
) {
    var host by remember { mutableStateOf(DEFAULT_PROXY_HOST) }
    var port by remember { mutableStateOf(DEFAULT_PROXY_PORT) }
    var target by remember { mutableStateOf(DEFAULT_TARGET) }
    var loading by remember { mutableStateOf(false) }
    var result by remember { mutableStateOf<FetchResult?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    fun run() {
        loading = true; result = null; error = null
        fetch(host, port.toIntOrNull() ?: 0, target) { r ->
            loading = false
            r.onSuccess { result = it }.onFailure { error = it.message ?: it.toString() }
        }
    }

    LaunchedEffect(Unit) { run() }

    Surface(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().padding(20.dp).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Proxycept Android Demo", style = MaterialTheme.typography.headlineSmall)

            OutlinedTextField(host, { host = it }, label = { Text("Proxy host") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(
                port, { port = it }, label = { Text("Proxy port") }, singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number), modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(target, { target = it }, label = { Text("URL") }, singleLine = true, modifier = Modifier.fillMaxWidth())

            Button(onClick = ::run, enabled = !loading, modifier = Modifier.fillMaxWidth()) {
                Text("Fetch through Proxycept")
            }

            if (loading) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                    Text("Requesting…")
                }
            }
            error?.let {
                Card(colors = CardDefaults.cardColors(containerColor = Color(0xFFFDECEA))) {
                    Text("Error: $it", Modifier.padding(12.dp), color = Color(0xFFB3261E))
                }
            }
            result?.let { r ->
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Text(r.statusLine, style = MaterialTheme.typography.titleMedium)
                        Text(
                            if (r.intercepted) "✓ Intercepted by Proxycept" else "✗ Not intercepted",
                            color = if (r.intercepted) Color(0xFF1B873F) else Color(0xFFB26A00),
                            style = MaterialTheme.typography.titleSmall,
                        )
                        Text("TLS cert issued by: ${r.tlsIssuer}", style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                        Text(r.bodyPreview, style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
    }
}
