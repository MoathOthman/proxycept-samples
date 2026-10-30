@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, kotlinx.cinterop.BetaInteropApi::class)
package com.proxycept.logging.kmp

import kotlinx.cinterop.*
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import okio.Buffer
import platform.Foundation.*
import platform.darwin.NSObject
import platform.posix.memcpy
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Dedicated ephemeral session; default Apple TLS validation, no cookies/cache/credential storage. */
internal class AppleTransport : Transport {
    override suspend fun post(endpoint: String, ingestKey: String, body: ByteArray): Response {
        checkToken(ingestKey)
        val url = NSURL.URLWithString(endpoint) ?: error("Invalid endpoint")
        val origin = "${url.scheme}://${url.host}${url.port?.let { ":$it" } ?: ""}"
        // NSURL.host omits brackets for IPv6 on some SDK versions.
        val normalized = if (url.host == "::1") "${url.scheme}://[::1]${url.port?.let { ":$it" } ?: ""}" else origin
        require(com.proxycept.logging.kmp.endpoint(normalized) == endpoint)
        return withTimeout(10_000) { suspendCancellableCoroutine { continuation ->
            val configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration.apply {
                HTTPShouldSetCookies = false; HTTPCookieStorage = null; URLCredentialStorage = null; URLCache = null
                timeoutIntervalForRequest = 10.0; timeoutIntervalForResource = 15.0
            }
            val delegate = ReplyDelegate { response, error ->
                if (continuation.isActive) {
                    if (error != null) continuation.resumeWithException(error) else continuation.resume(response!!)
                }
            }
            val session = NSURLSession.sessionWithConfiguration(configuration, delegate, NSOperationQueue().apply { maxConcurrentOperationCount = 1 })
            val request = NSMutableURLRequest.requestWithURL(url).apply {
                HTTPMethod = "POST"
                setValue("Bearer $ingestKey", forHTTPHeaderField = "Authorization")
                setValue("application/json; charset=utf-8", forHTTPHeaderField = "Content-Type")
                setValue("application/json", forHTTPHeaderField = "Accept")
                HTTPBody = body.usePinned { NSData.create(bytes = it.addressOf(0), length = body.size.toULong()) }
            }
            val task = session.dataTaskWithRequest(request)
            continuation.invokeOnCancellation { task.cancel(); session.invalidateAndCancel() }
            task.resume()
        } }
    }
}
private class ReplyDelegate(private val complete: (Response?, Exception?) -> Unit) : NSObject(), NSURLSessionDataDelegateProtocol {
    private val buffer = Buffer()
    private var overflow = false
    override fun URLSession(session: NSURLSession, dataTask: NSURLSessionDataTask, didReceiveData: NSData) {
        if (didReceiveData.length > (16_384L - buffer.size).toULong()) { overflow = true; dataTask.cancel(); return }
        val bytes = ByteArray(didReceiveData.length.toInt())
        if (bytes.isNotEmpty()) bytes.usePinned { memcpy(it.addressOf(0), didReceiveData.bytes, didReceiveData.length) }
        buffer.write(bytes)
    }
    override fun URLSession(session: NSURLSession, task: NSURLSessionTask, willPerformHTTPRedirection: NSHTTPURLResponse,
        newRequest: NSURLRequest, completionHandler: (NSURLRequest?) -> Unit) {
        // Refuse every redirect before Foundation sends credentials to any redirected endpoint.
        completionHandler(null)
    }
    override fun URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError: NSError?) {
        val response = task.response as? NSHTTPURLResponse
        if (overflow || didCompleteWithError != null || response == null) complete(null, IllegalStateException("Transport failed"))
        else complete(Response(response.statusCode.toInt(), buffer.readUtf8(), response.valueForHTTPHeaderField("Retry-After")), null)
        session.finishTasksAndInvalidate()
    }
}
