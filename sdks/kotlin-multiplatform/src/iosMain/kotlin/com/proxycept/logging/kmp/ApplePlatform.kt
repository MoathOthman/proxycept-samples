@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.proxycept.logging.kmp

import kotlinx.cinterop.*
import platform.Foundation.*
import platform.posix.*

internal actual class StateLock {
    private val lock = NSLock()
    actual fun <T> locked(block: () -> T): T { lock.lock(); try { return block() } finally { lock.unlock() } }
}
internal actual fun randomId(): String = NSUUID().UUIDString.lowercase()
internal actual fun openPrivateLease(directory: String): PlatformLease {
    val manager = NSFileManager.defaultManager
    check(manager.createDirectoryAtPath(directory, withIntermediateDirectories = true,
        attributes = mapOf(NSFileProtectionKey to NSFileProtectionCompleteUntilFirstUserAuthentication), error = null)) { "Cannot create protected spool" }
    check(chmod(directory, 448u) == 0) { "Cannot protect spool" }
    val url = NSURL.fileURLWithPath(directory, isDirectory = true)
    check(url.setResourceValue(true, forKey = NSURLIsExcludedFromBackupKey, error = null)) { "Cannot exclude spool from backup" }
    check(manager.setAttributes(mapOf(NSFileProtectionKey to NSFileProtectionCompleteUntilFirstUserAuthentication), ofItemAtPath = directory, error = null))
    preparePrivateFile("$directory/owner.lock")
    val fd = open("$directory/owner.lock", O_RDWR)
    check(fd >= 0) { "Cannot open spool lock" }
    if (flock(fd, LOCK_EX or LOCK_NB) != 0) { close(fd); error("Spool is already owned") }
    return object : PlatformLease { override fun close() { flock(fd, LOCK_UN); platform.posix.close(fd) } }
}
internal actual fun preparePrivateFile(path: String) {
    val fd = open(path, O_CREAT or O_RDWR, 384)
    check(fd >= 0) { "Cannot create private spool file" }
    try {
        check(fchmod(fd, 384u) == 0)
        check(NSFileManager.defaultManager.setAttributes(
            mapOf(NSFileProtectionKey to NSFileProtectionCompleteUntilFirstUserAuthentication), ofItemAtPath = path, error = null))
    } finally { close(fd) }
}
internal actual fun syncFile(path: String) {
    val fd = open(path, O_RDONLY)
    check(fd >= 0)
    try { check(fsync(fd) == 0) } finally { close(fd) }
}
internal actual fun defaultTransport(): Transport = AppleTransport()
