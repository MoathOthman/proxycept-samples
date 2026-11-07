package com.proxycept.logging.kmp

import okio.FileSystem
import okio.Path.Companion.toPath
import okio.buffer
import okio.use

internal interface Storage {
    val installationId: String
    fun load(policy: Configuration, now: Long): Pair<List<Record>, Long>
    fun save(records: List<Record>)
    fun close()
}
internal class PrivateStorage(directory: String) : Storage {
    private val path = directory.toPath(normalize = true)
    private val lease = openPrivateLease(path.toString())
    private val fs = FileSystem.SYSTEM
    private val snapshot = path / "queue.jsonl"
    private val temp = path / "queue.tmp"
    override val installationId: String
    init {
        try {
            fs.delete(temp, mustExist = false)
            val identity = path / "installation-id"
            val old = if (fs.exists(identity) && (fs.metadata(identity).size ?: MAX_BYTES.toLong()) <= 128) fs.read(identity) { readUtf8() } else ""
            installationId = if (old.matches(Regex("[0-9a-fA-F-]{36}"))) old else randomId().also { value ->
                preparePrivateFile(identity.toString()); fs.write(identity) { writeUtf8(value) }; syncFile(identity.toString())
            }
        } catch (error: Throwable) { lease.close(); throw error }
    }
    override fun load(policy: Configuration, now: Long): Pair<List<Record>, Long> {
        if (!fs.exists(snapshot)) return emptyList<Record>() to 0
        if ((fs.metadata(snapshot).size ?: Long.MAX_VALUE) > MAX_BYTES) { fs.delete(snapshot); return emptyList<Record>() to 1 }
        var bad = 0L
        val records = ArrayList<Record>()
        fs.source(snapshot).buffer().use { source ->
            while (!source.exhausted()) {
                val line = source.readUtf8Line() ?: break
                try {
                    require(line.encodeToByteArray().size <= 16_384)
                    val record = Record.recover(line, policy)
                    if (record.createdAt > now || now - record.createdAt >= EXPIRY) bad++ else records.add(record)
                } catch (_: Exception) { bad++ }
            }
        }
        return records to bad
    }
    override fun save(records: List<Record>) {
        try {
            preparePrivateFile(temp.toString())
            fs.write(temp) { records.forEach { writeUtf8(it.line); writeByte(10) } }
            syncFile(temp.toString()); fs.atomicMove(temp, snapshot)
        } finally { fs.delete(temp, mustExist = false) }
    }
    override fun close() = lease.close()
}
