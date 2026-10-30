package com.proxycept.logging.kmp

import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.net.URI
import java.util.UUID
import java.util.concurrent.locks.ReentrantLock
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal actual class StateLock {
    private val lock = ReentrantLock()
    actual fun <T> locked(block: () -> T): T { lock.lock(); try { return block() } finally { lock.unlock() } }
}
internal actual fun randomId() = UUID.randomUUID().toString()
internal actual fun openPrivateLease(directory: String): PlatformLease {
    val dir = File(directory)
    require(dir.isDirectory || dir.mkdirs()) { "Cannot create private spool" }
    check(dir.setReadable(false, false) && dir.setWritable(false, false) && dir.setExecutable(false, false))
    check(dir.setReadable(true, true) && dir.setWritable(true, true) && dir.setExecutable(true, true))
    preparePrivateFile(File(dir, "owner.lock").path)
    val file = RandomAccessFile(File(dir, "owner.lock"), "rw")
    val lock = try { file.channel.tryLock() ?: error("Spool is already owned") }
    catch (error: Throwable) { file.close(); throw error }
    return object : PlatformLease { override fun close() { try { lock.release() } finally { file.close() } } }
}
internal actual fun preparePrivateFile(path: String) {
    val file = File(path)
    if (!file.exists()) check(file.createNewFile()) { "Cannot create private spool file" }
    check(file.isFile && file.setReadable(false, false) && file.setWritable(false, false) && file.setExecutable(false, false))
    check(file.setReadable(true, true) && file.setWritable(true, true))
}
internal actual fun syncFile(path: String) { FileOutputStream(File(path), true).use { it.fd.sync() } }
internal actual fun defaultTransport(): Transport = JavaTransport()

internal class JavaTransport(
    private val totalTimeoutMillis: Long = 10_000,
    private val client: OkHttpClient = sharedClient
) : Transport {
    companion object {
        // Explicit isolation from application cookie jars, authenticators and redirect policy.
        private val sharedClient = OkHttpClient.Builder()
            .followRedirects(false).followSslRedirects(false)
            .cookieJar(CookieJar.NO_COOKIES).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
            .callTimeout(10, TimeUnit.SECONDS).connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS).writeTimeout(10, TimeUnit.SECONDS)
            .dispatcher(Dispatcher(Executors.newCachedThreadPool { task ->
                Thread(task, "proxycept-kmp-http").apply { isDaemon = true }
            })).build()
    }
    override suspend fun post(endpoint: String, ingestKey: String, body: ByteArray): Response = withTimeout(totalTimeoutMillis) {
        checkToken(ingestKey)
        val origin = URI(endpoint).let { URI(it.scheme, null, it.host, it.port, null, null, null).toString() }
        require(com.proxycept.logging.kmp.endpoint(origin) == endpoint)
        val request = Request.Builder().url(endpoint)
            .header("Authorization", "Bearer $ingestKey").header("Accept", "application/json")
            .header("Accept-Encoding", "identity")
            .post(body.toRequestBody("application/json; charset=utf-8".toMediaType())).build()
        suspendCancellableCoroutine { continuation ->
            val call = client.newCall(request)
            // Cancellation closes the actual socket, including blocked response reads/request writes.
            // The coroutine deadline is independent of per-read progress and callback completion.
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) {
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
                override fun onResponse(call: Call, response: okhttp3.Response) {
                    try {
                        response.use {
                            val output = java.io.ByteArrayOutputStream()
                            it.body?.byteStream()?.use { input ->
                                val buffer = ByteArray(1024)
                                while (true) {
                                    val n = input.read(buffer)
                                    if (n < 0) break
                                    check(output.size() + n <= 16_384) { "Acknowledgement exceeds limit" }
                                    output.write(buffer, 0, n)
                                }
                            }
                            val result = Response(it.code, output.toByteArray().decodeToString(), it.header("Retry-After"))
                            if (continuation.isActive) continuation.resume(result)
                        }
                    } catch (error: Exception) { if (continuation.isActive) continuation.resumeWithException(error) }
                }
            })
        }
    }
}
