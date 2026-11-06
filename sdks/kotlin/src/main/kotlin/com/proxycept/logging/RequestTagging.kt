package com.proxycept.logging

import java.net.HttpURLConnection
import java.util.UUID

/**
 * Implementation of [ProxyceptLogger.tag] / [ProxyceptLogger.tagHeaders]. Opt-in request
 * tagging: nothing here runs unless the app calls it on a request it builds. There is no
 * interceptor, global hook, or automatic header injection.
 *
 * Only tag requests to endpoints your app controls. Do not tag signed requests (for example
 * AWS SigV4 or HMAC-signed) or third-party requests: an added header can break their
 * signature or leak an identifier to another party.
 *
 * Invalid IDs never throw and are never sent: a fresh UUID replaces them, so always log
 * with the returned value. Valid IDs are 1-128 visible ASCII characters (no spaces,
 * control characters, CR or LF).
 */
internal object RequestTagging {
    const val CORRELATION_HEADER = "X-Proxycept-Correlation-ID"

    fun isValidCorrelationId(value: String?): Boolean =
        value != null && value.isNotEmpty() && value.length <= 128 && value.all { it in '!'..'~' }

    fun tag(connection: HttpURLConnection, correlationId: String?): String {
        val id = choose(correlationId) { connection.getRequestProperty(CORRELATION_HEADER) }
        connection.setRequestProperty(CORRELATION_HEADER, id)
        return id
    }

    fun tagHeaders(headers: MutableMap<String, String>, correlationId: String?): String {
        val keys = headers.keys.filter { it.equals(CORRELATION_HEADER, ignoreCase = true) }
        val id = choose(correlationId) { keys.map { headers[it] }.firstOrNull { isValidCorrelationId(it) } }
        keys.forEach { headers.remove(it) }
        headers[CORRELATION_HEADER] = id
        return id
    }

    private inline fun choose(explicit: String?, existing: () -> String?): String = when {
        explicit != null -> explicit.takeIf { isValidCorrelationId(it) }
        else -> existing()?.takeIf { isValidCorrelationId(it) }
    } ?: UUID.randomUUID().toString()
}
