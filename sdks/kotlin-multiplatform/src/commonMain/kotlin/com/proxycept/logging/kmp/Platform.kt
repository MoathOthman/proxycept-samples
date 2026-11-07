package com.proxycept.logging.kmp

internal expect class StateLock() { fun <T> locked(block: () -> T): T }
internal expect fun randomId(): String
internal expect fun openPrivateLease(directory: String): PlatformLease
internal expect fun preparePrivateFile(path: String)
internal expect fun syncFile(path: String)
internal interface PlatformLease { fun close() }
internal expect fun defaultTransport(): Transport
