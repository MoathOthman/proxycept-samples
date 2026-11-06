package com.proxycept.logging

import java.net.HttpURLConnection
import java.net.URI

/** Implementations must not redirect requests, downgrade TLS, or retain credentials. */
fun interface Transport {
    fun post(endpoint: URI, token: String, body: ByteArray): Response
}
data class Response(val status: Int, val body: String = "", val retryAfter: String? = null)

internal fun ingestEndpoint(baseUrl: String): URI {
    val base = URI(baseUrl)
    require(base.isAbsolute && base.host != null && base.rawUserInfo == null &&
        base.rawQuery == null && base.rawFragment == null) { "Invalid base URL" }
    // Numeric loopback only: no DNS rebinding or hostnames that resolve outside loopback.
    val loopback = base.host in setOf("127.0.0.1", "[::1]", "::1")
    require(base.scheme == "https" || (base.scheme == "http" && loopback)) { "HTTPS required" }
    require(base.port == -1 || base.port in 1..65535)
    require(base.path.isNullOrEmpty() || base.path == "/") { "Base URL must be an origin" }
    return base.resolve("/api/logs/ingest")
}

/** Uses platform TLS trust and hostname verification; never follows even same-origin redirects. */
class UrlConnectionTransport(private val timeoutMillis: Int = 10_000) : Transport {
    init { require(timeoutMillis in 1..60_000) }
    override fun post(endpoint: URI, token: String, body: ByteArray): Response {
        require(ingestEndpoint(URI(endpoint.scheme, null, endpoint.host, endpoint.port, "/", null, null).toString()) == endpoint)
        validateToken(token)
        val connection = endpoint.toURL().openConnection() as HttpURLConnection
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = timeoutMillis
            connection.readTimeout = timeoutMillis
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
            connection.setRequestProperty("Accept", "application/json")
            connection.setFixedLengthStreamingMode(body.size)
            connection.outputStream.use { it.write(body) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            // Acknowledgements are tiny. Bound hostile response allocation, including error pages.
            val bytes = stream?.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(1024)
                while (output.size() < 16_384) {
                    val n = input.read(buffer, 0, minOf(buffer.size, 16_384 - output.size()))
                    if (n < 0) break
                    output.write(buffer, 0, n)
                }
                output.toByteArray()
            } ?: ByteArray(0)
            return Response(status, String(bytes, Charsets.UTF_8), connection.getHeaderField("Retry-After"))
        } finally { connection.disconnect() }
    }
}

internal fun validateToken(token: String) {
    require(token.matches(Regex("plog_ingest_[A-Za-z0-9_-]{1,500}"))) { "Invalid ingest token" }
}
