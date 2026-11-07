package com.proxycept.logging.kmp

import kotlinx.datetime.*
import kotlinx.serialization.json.*

internal const val MAX_BYTES = 2 * 1024 * 1024
internal const val EXPIRY = 3L * 24 * 60 * 60 * 1000
internal val json = Json { isLenient = false; allowSpecialFloatingPointValues = false }
internal fun encoded(value: JsonElement) = value.toString().encodeToByteArray()
internal fun clip(value: String, max: Int): String = value.take(max).let {
    if (it.isNotEmpty() && it.last().isHighSurrogate()) it.dropLast(1) else it
}
internal fun endpoint(base: String): String {
    val match = Regex("^(https|http)://(\\[[a-fA-F0-9:]+]|[a-zA-Z0-9.-]+)(?::([0-9]{1,5}))?/?$").matchEntire(base)
        ?: throw IllegalArgumentException("Expected server origin without path, credentials, query or fragment")
    val scheme = match.groupValues[1]
    val host = match.groupValues[2].lowercase()
    val port = match.groupValues[3]
    require(port.isEmpty() || port.toInt() in 1..65535) { "Invalid port" }
    require(scheme == "https" || host == "127.0.0.1" || host == "[::1]") { "HTTPS required except numeric loopback" }
    return "$scheme://$host${if (port.isEmpty()) "" else ":$port"}/api/logs/ingest"
}
internal fun checkToken(token: String) { require(token.matches(Regex("plog_ingest_[A-Za-z0-9_-]{1,500}"))) { "Invalid ingest credential" } }

fun interface Redactor { fun redact(text: String): String }
internal object Scrub {
    private val bearer = Regex("(?i)\\bBearer\\s+[^\\s\"',;]+")
    private val ingest = Regex("plog_ingest_[A-Za-z0-9_-]+")
    private val assignment = Regex("(?i)(password|passwd|secret|token|api[_-]?key|authorization|cookie)\\s*[:=]\\s*[^\\s,;]+")
    val key = Regex("(?i).*(password|passwd|secret|token|authorization|cookie|api.?key|email|phone|address|credential).*")
    // One pass rather than an unanchored email regex: Kotlin/Native's regex engine can
    // otherwise backtrack quadratically on a long, ordinary message without an '@'.
    private fun emailLikeTokens(text: String): String {
        if ('@' !in text) return text
        return buildString {
            var start = 0
            var hasAt = false
            for (index in text.indices) {
                val char = text[index]
                if (char.isWhitespace()) {
                    append(if (hasAt) "[REDACTED]" else text.substring(start, index))
                    append(char); start = index + 1; hasAt = false
                } else if (char == '@') hasAt = true
            }
            append(if (hasAt) "[REDACTED]" else text.substring(start))
        }
    }
    private fun builtin(text: String) = emailLikeTokens(assignment.replace(ingest.replace(bearer.replace(text,
        "[REDACTED]"), "[REDACTED]"), "[REDACTED]"))
    fun text(text: String, policy: Configuration): String = builtin(policy.redactor.redact(
        builtin(text.replace(policy.ingestKey, "[REDACTED]"))).replace(policy.ingestKey, "[REDACTED]"))
}

internal fun attributes(values: Map<String, Any?>, policy: Configuration): JsonObject = buildJsonObject {
    values.entries.take(16).forEach { (key, value) ->
        require(key.isNotEmpty()) { "Attribute names must be nonempty" }
        val scalar: JsonElement = when (value) {
            null -> JsonNull
            is String -> JsonPrimitive(clip(Scrub.text(value, policy), 512))
            is Boolean -> JsonPrimitive(value)
            is Byte -> JsonPrimitive(value)
            is Short -> JsonPrimitive(value)
            is Int -> JsonPrimitive(value)
            is Long -> JsonPrimitive(value)
            is Float -> { require(value.isFinite() && value.toDouble() in -1e308..1e308); JsonPrimitive(value) }
            is Double -> { require(value.isFinite() && value in -1e308..1e308); JsonPrimitive(value) }
            else -> throw IllegalArgumentException("Attributes require finite bounded JSON scalars")
        }
        val name = clip(Scrub.text(key, policy), 64)
        require(name.isNotEmpty())
        put(name, if (Scrub.key.matches(key)) JsonPrimitive("[REDACTED]") else scalar)
    }
}
internal fun scalarMap(obj: JsonObject): Map<String, Any?> = obj.mapValues { (_, value) ->
    if (value === JsonNull) null else {
        require(value is JsonPrimitive)
        when {
            value.isString -> value.content
            value.booleanOrNull != null -> value.boolean
            value.longOrNull != null -> value.long
            else -> value.double
        }
    }
}
internal fun makeEvent(level: Level, category: String, message: String, attrs: Map<String, Any?>,
    correlation: String?, id: String, sequence: Long, time: String, policy: Configuration): JsonObject {
    require(id.length in 1..128 && sequence >= 0)
    Instant.parse(time)
    return buildJsonObject {
        put("event_id", id); put("sequence", sequence); put("client_time", time)
        put("severity", level.name.lowercase()); put("category", clip(Scrub.text(category, policy), 80))
        put("message", clip(Scrub.text(message, policy), 4096)); put("attributes", attributes(attrs, policy))
        put("correlation_id", correlation?.takeIf { it.isNotEmpty() }?.let {
            clip(Scrub.text(it, policy), 128).takeIf { clean -> clean.isNotEmpty() }?.let(::JsonPrimitive)
        } ?: JsonNull)
    }.also { require(encoded(it).size <= 8192) { "Event exceeds wire limit" } }
}
internal fun metadataIdentifier(value: String, policy: Configuration): String =
    clip(Scrub.text(value, policy), 128).also { require(it.length in 1..128) { "Metadata identifier must remain nonempty" } }

internal fun metadata(policy: Configuration, installation: String): JsonObject = buildJsonObject {
    put("schema_version", 1); put("app_version", clip(Scrub.text(policy.appVersion, policy), 80))
    put("build", clip(Scrub.text(policy.build, policy), 80)); put("installation_id", metadataIdentifier(installation, policy))
    put("debug_session_id", metadataIdentifier(policy.debugSessionId, policy))
}
internal class Record(val createdAt: Long, val metadata: JsonObject, val event: JsonObject) {
    val id = event.getValue("event_id").jsonPrimitive.content
    fun tree() = buildJsonObject { put("stored_at", createdAt); put("metadata", metadata); put("event", event) }
    val line = tree().toString()
    val size = line.encodeToByteArray().size + 1
    companion object {
        fun recover(line: String, policy: Configuration): Record {
            val root = json.parseToJsonElement(line).jsonObject
            val e = root.getValue("event").jsonObject
            val m = root.getValue("metadata").jsonObject
            require(m.getValue("schema_version").jsonPrimitive.int == 1)
            val meta = buildJsonObject {
                put("schema_version", 1)
                listOf("app_version", "build", "installation_id", "debug_session_id").forEach { key ->
                    val max = if (key == "app_version" || key == "build") 80 else 128
                    val value = m.getValue(key).jsonPrimitive.content
                    if (key == "installation_id" || key == "debug_session_id") {
                        require(value.length in 1..128)
                        put(key, metadataIdentifier(value, policy))
                    } else {
                        require(value.length <= max)
                        put(key, clip(Scrub.text(value, policy), max))
                    }
                }
            }
            return Record(root.getValue("stored_at").jsonPrimitive.long, meta, makeEvent(
                Level.valueOf(e.getValue("severity").jsonPrimitive.content.uppercase()),
                e.getValue("category").jsonPrimitive.content, e.getValue("message").jsonPrimitive.content,
                scalarMap(e.getValue("attributes").jsonObject), e["correlation_id"]?.jsonPrimitive?.contentOrNull,
                e.getValue("event_id").jsonPrimitive.content, e.getValue("sequence").jsonPrimitive.long,
                e.getValue("client_time").jsonPrimitive.content, policy))
        }
    }
}
internal data class Ack(val accepted: Int, val duplicate: Int)
internal fun acknowledgement(body: String, size: Int): Ack? = runCatching {
    val obj = json.parseToJsonElement(body).jsonObject
    fun count(key: String): Int {
        val p = obj.getValue(key).jsonPrimitive
        require(!p.isString && p.content.matches(Regex("0|[1-9][0-9]*")))
        return p.int.also { require(it in 0..size) }
    }
    val a = count("accepted"); val d = count("duplicate")
    require(a.toLong() + d == size.toLong()); Instant.parse(obj.getValue("received_at").jsonPrimitive.content)
    Ack(a, d)
}.getOrNull()
internal fun retryAfter(value: String?, now: Long): Long {
    if (value == null) return 0
    value.trim().toLongOrNull()?.let { return it.coerceIn(0, Long.MAX_VALUE / 1000) * 1000 }
    return runCatching {
        val parts = value.trim().split(Regex("\\s+"))
        require(parts.size == 6 && parts[5] == "GMT")
        val month = listOf("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec").indexOf(parts[2]) + 1
        val t = parts[4].split(':').map { it.toInt() }
        (LocalDateTime(parts[3].toInt(), month, parts[1].toInt(), t[0], t[1], t[2]).toInstant(TimeZone.UTC).toEpochMilliseconds() - now).coerceAtLeast(0)
    }.getOrDefault(0)
}
