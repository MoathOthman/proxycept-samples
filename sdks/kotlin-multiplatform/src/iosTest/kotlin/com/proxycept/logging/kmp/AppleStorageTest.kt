@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.proxycept.logging.kmp

import kotlinx.datetime.Clock
import platform.Foundation.*
import kotlin.test.*

class AppleStorageTest {
    @Test fun protectedPrivateSpoolModesRecoveryAndExclusiveLease() {
        val path = NSTemporaryDirectory() + "proxycept-kmp-native-" + randomId()
        val policy = Configuration("http://127.0.0.1:18880", "plog_ingest_nativeTest", path, "1", "1")
        val storage = PrivateStorage(path)
        try {
            assertFails { PrivateStorage(path) }
            val now = Clock.System.now().toEpochMilliseconds()
            val record = Record(now, metadata(policy, storage.installationId), makeEvent(Level.INFO, "native", "native-store",
                mapOf("password" to "never-persist"), null, randomId(), 1, Clock.System.now().toString(), policy))
            storage.save(listOf(record))
            for (name in listOf("installation-id", "queue.jsonl", "owner.lock")) {
                val attrs = NSFileManager.defaultManager.attributesOfItemAtPath("$path/$name", null)!!
                val mode = attrs[NSFilePosixPermissions] as NSNumber
                assertEquals(384, mode.intValue, name)
            }
            val recovered = storage.load(policy, now + 1).first.single()
            assertEquals(record.id, recovered.id)
            assertFalse(recovered.line.contains("never-persist"))
        } finally { storage.close(); NSFileManager.defaultManager.removeItemAtPath(path, null) }
    }
}
