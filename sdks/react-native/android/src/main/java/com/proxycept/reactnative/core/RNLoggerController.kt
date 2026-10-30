package com.proxycept.reactnative.core

import com.google.gson.JsonObject
import com.google.gson.JsonParser
import java.io.File
import java.util.UUID

/** Call on one dedicated worker. No Android/RN dependency: test the real adapter with JVM tests. */
class RNLoggerController(private val root: File, private val transport: Transport = UrlConnectionTransport()) {
    @Volatile private var logger: ProxyceptLogger? = null
    @Volatile private var foregroundActive = false
    private var configuration: Configuration? = null
    private var terminal: String? = null

    fun configure(json: String) {
        check(logger == null)
        require(json.toByteArray(Charsets.UTF_8).size <= 8192)
        val input = JsonParser.parseString(json).asJsonObject
        val name = input.get("spoolName")?.asString ?: "default"
        require(name.matches(Regex("[A-Za-z0-9_-]{1,64}")))
        val config = Configuration(baseUrl = input.get("baseUrl").asString,
            ingestToken = input.get("ingestToken").asString, directory = File(root, name),
            appVersion = input.get("appVersion").asString, build = input.get("build").asString,
            maxQueueBytes = input.get("maxQueueBytes")?.asInt ?: 2 * 1024 * 1024,
            maxQueueEvents = input.get("maxQueueEvents")?.asInt ?: 2000,
            installationId = input.get("installationId")?.asString,
            debugSessionId = input.get("debugSessionId")?.asString ?: UUID.randomUUID().toString())
        val engine = ProxyceptLogger(config, transport)
        engine.setForegroundActive(foregroundActive)
        logger = engine; configuration = config; terminal = null
    }
    fun log(json: String): Boolean {
        val logger = logger ?: return false
        return runCatching {
            require(json.toByteArray(Charsets.UTF_8).size <= 65536)
            val event = JsonParser.parseString(json).asJsonObject
            val level = event.get("level").asString
            require(level in setOf("debug", "info", "warning", "error"))
            val category = event.get("category").asString; val message = event.get("message").asString
            require(category.codePointCount(0, category.length) <= 80 && message.codePointCount(0, message.length) <= 4096)
            val attributes = event.getAsJsonObject("attributes")
            require(attributes.size() <= 16)
            val values = attributes.entrySet().associate { (key, value) ->
                require(key.isNotEmpty() && key.codePointCount(0, key.length) <= 64)
                key to when {
                    value.isJsonNull -> null
                    !value.isJsonPrimitive -> error("Scalar required")
                    value.asJsonPrimitive.isBoolean -> value.asBoolean
                    value.asJsonPrimitive.isString -> value.asString.also { require(it.codePointCount(0, it.length) <= 512) }
                    value.asJsonPrimitive.isNumber -> value.asDouble.also { require(it.isFinite() && it in -1e308..1e308) }
                    else -> error("Scalar required")
                }
            }
            val correlation = readCorrelationId(event.get("correlationId"))
            logger.log(Level.valueOf(level.uppercase(java.util.Locale.US)), category, message, values, correlation)
        }.getOrDefault(false)
    }
    fun flush() {
        val logger = logger ?: return
        // Kotlin flush is asynchronous and one-batch-at-a-time; use its bounded barrier
        // on this worker to provide the same drain-until-failure contract as Swift.
        repeat(40) {
            val before = logger.stats().queuedEvents
            logger.drain()
            val after = logger.stats().queuedEvents
            if (after == 0 || after >= before) return
        }
    }
    fun foreground(active: Boolean) { foregroundActive = active; logger?.setForegroundActive(active) }
    fun reconfigure(token: String) {
        val old = configuration ?: error("Not configured")
        val next = Configuration(old.baseUrl, token, old.directory, old.appVersion, old.build,
            old.maxQueueBytes, old.maxQueueEvents, old.redactor, old.installationId, old.debugSessionId)
        checkNotNull(logger).reconfigure(next); configuration = next
    }
    fun disable() {
        logger?.disable()
        // Await the ordered purge, including any in-flight transport and snapshot write.
        logger?.awaitIdle()
    }
    fun close() {
        val current = logger ?: return
        current.close(); terminal = encode(current.stats()); logger = null; configuration = null
    }
    fun deliveryStats(): String = logger?.let { encode(it.stats()) } ?: terminal ?: "{}"
    private fun encode(stats: DeliveryStats): String = JsonObject().apply {
        addProperty("queued", stats.queuedEvents); addProperty("accepted", stats.accepted)
        addProperty("duplicate", stats.duplicates); addProperty("dropped", stats.dropped)
        addProperty("expired", stats.expired); addProperty("failures", stats.retries)
        addProperty("storageFailures", stats.storageFailures)
        addProperty("authenticationStopped", stats.stoppedForAuthentication)
        addProperty("disabled", stats.disabled || stats.closed)
    }.toString()
}
