package com.proxycept.logging.kmp

import kotlinx.serialization.json.jsonObject

/** Default-argument-free factory for Swift/ObjC integration. */
object LoggingSdk {
    fun create(baseUrl: String, ingestKey: String, spoolDirectory: String, appVersion: String, build: String): ProxyceptLogger =
        ProxyceptLogger(Configuration(baseUrl, ingestKey, spoolDirectory, appVersion, build))
}
