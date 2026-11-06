package com.proxycept.logging

import com.google.gson.GsonBuilder
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal val gson = GsonBuilder().serializeNulls().disableHtmlEscaping().create()
internal fun bytes(value: Any): ByteArray = gson.toJson(value).toByteArray(Charsets.UTF_8)
internal fun isoTime(now: Long): String = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
    timeZone = TimeZone.getTimeZone("UTC")
}.format(Date(now))
internal fun clipped(value: String, limit: Int): String = value.take(limit).let {
    if (it.isNotEmpty() && Character.isHighSurrogate(it.last())) it.dropLast(1) else it
}

/** Best effort only. Do not log secrets or sensitive personal data intentionally. */
fun interface Redactor { fun redact(value: String): String }
internal object DefaultRedactor : Redactor {
    private val bearer = Regex("(?i)\\bBearer\\s+[^\\s\"',;]+")
    private val ingest = Regex("plog_ingest_[A-Za-z0-9_-]+")
    private val email = Regex("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}")
    private val assignment = Regex("(?i)(password|passwd|secret|token|api[_-]?key|authorization|cookie)\\s*[:=]\\s*[^\\s,;]+")
    override fun redact(value: String): String = email.replace(assignment.replace(
        ingest.replace(bearer.replace(value, "[REDACTED]"), "[REDACTED]"), "[REDACTED]"), "[REDACTED]")
}
internal val sensitiveKey = Regex("(?i).*(password|passwd|secret|token|authorization|cookie|api.?key|email|phone|address|credential).*")

internal data class Record(val storedAt: Long, val metadata: JsonObject, val event: JsonObject) {
    fun json(): JsonObject = JsonObject().apply {
        addProperty("stored_at", storedAt); add("metadata", metadata); add("event", event)
    }
    val size: Int by lazy { bytes(json()).size + 1 }
    val id: String get() = event.get("event_id").asString
    companion object {
        fun parse(line: String): Record {
            val root = JsonParser.parseString(line).asJsonObject
            val record = Record(root.get("stored_at").asLong, root.getAsJsonObject("metadata"), root.getAsJsonObject("event"))
            require(validIsoTime(record.event.get("client_time").asString))
            require(record.id.length in 1..128 && record.event.get("sequence").asLong >= 0)
            require(record.event.get("severity").asString in listOf("debug", "info", "warning", "error"))
            require(bytes(record.event).size <= 8192)
            return record
        }
    }
}

internal fun validIsoTime(value: String): Boolean {
    val match = Regex("^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(?:\\.(\\d{1,9}))?(Z|[+-]\\d{2}:\\d{2})$").matchEntire(value) ?: return false
    val fraction = match.groupValues[2].padEnd(3, '0').take(3)
    val zone = match.groupValues[3].let { if (it == "Z") "+0000" else it.replace(":", "") }
    val normalized = "${match.groupValues[1]}.$fraction$zone"
    val position = java.text.ParsePosition(0)
    val format = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US).apply { isLenient = false }
    return format.parse(normalized, position) != null && position.index == normalized.length
}
