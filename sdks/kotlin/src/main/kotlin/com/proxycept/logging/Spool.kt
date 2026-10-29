package com.proxycept.logging

import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.UUID

internal interface Storage : AutoCloseable {
    fun installationId(): String
    fun load(maxBytes: Int, maxEvents: Int, now: Long, expiry: Long): Pair<List<Record>, Long>
    fun save(records: Collection<Record>)
}

/** Dedicated directory, one owner; atomic snapshot + advisory lock. No config or token is written. */
internal class Spool(val directory: File) : Storage {
    private val lockFile: RandomAccessFile
    private val lock: java.nio.channels.FileLock
    private val snapshot = File(directory, "queue.jsonl")
    init {
        require(directory.isDirectory || directory.mkdirs()) { "Cannot create spool directory" }
        lockFile = RandomAccessFile(File(directory, "owner.lock"), "rw")
        try { lock = lockFile.channel.tryLock() ?: error("Spool directory already in use") }
        catch (e: Exception) { lockFile.close(); throw e }
        File(directory, "queue.tmp").delete()
    }
    override fun installationId(): String {
        val file = File(directory, "installation-id")
        if (file.isFile && file.length() <= 128) {
            val value = file.readText()
            if (runCatching { UUID.fromString(value) }.isSuccess) return value
        }
        val value = UUID.randomUUID().toString()
        FileOutputStream(file).use { it.write(value.toByteArray()); it.fd.sync() }
        return value
    }
    override fun load(maxBytes: Int, maxEvents: Int, now: Long, expiry: Long): Pair<List<Record>, Long> {
        if (!snapshot.isFile) return emptyList<Record>() to 0L
        if (snapshot.length() > maxBytes) { snapshot.delete(); return emptyList<Record>() to 1L }
        val records = ArrayList<Record>()
        var dropped = 0L
        snapshot.bufferedReader(Charsets.UTF_8).useLines { lines -> lines.forEach { line ->
            try {
                require(line.toByteArray().size <= 16_384)
                val record = Record.parse(line)
                if (record.storedAt > now || now - record.storedAt >= expiry || records.size >= maxEvents) dropped++
                else records.add(record)
            } catch (_: Exception) { dropped++ }
        } }
        return records to dropped
    }
    override fun save(records: Collection<Record>) {
        val temp = File(directory, "queue.tmp")
        try {
            FileOutputStream(temp).use { out ->
                records.forEach { out.write(bytes(it.json())); out.write(10) }
                out.fd.sync()
            }
            check(temp.renameTo(snapshot)) { "Cannot replace spool" }
        } finally { temp.delete() }
    }
    override fun close() { try { lock.release() } finally { lockFile.close() } }
}
