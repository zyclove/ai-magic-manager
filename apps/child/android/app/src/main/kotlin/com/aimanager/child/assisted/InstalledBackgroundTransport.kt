package com.aimanager.child.assisted

import com.nimbusds.jose.util.JSONObjectUtils
import java.net.URI
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection
import java.util.concurrent.atomic.AtomicBoolean

/** HTTPS only; routes and origin belong to the APK, never to remote data. */
class InstalledBackgroundTransport(root: String,
    private val open: (URL) -> HttpsURLConnection = { it.openConnection() as HttpsURLConnection },
    private val requestTimeoutMillis: Long = 15000L) : BackgroundTransport {
    private val root = URI(root.removeSuffix("/"))
    init {
        require(requestTimeoutMillis in 1..30000 && this.root.scheme == "https" && !this.root.host.isNullOrBlank() && this.root.rawUserInfo == null &&
            this.root.rawQuery == null && this.root.rawFragment == null && this.root.path.endsWith("/api/v1") &&
            this.root.path.split('/').none { it == "." || it == ".." } && this.root == this.root.normalize())
    }
    override fun request(method: String, path: String, credential: String, body: Map<String, Any?>?): BackgroundResponse {
        check(!Thread.currentThread().isInterrupted)
        require(method in setOf("GET", "POST") && secret(credential))
        require(path.matches(Regex("(?:heartbeats|credentials/(?:rotate|activate|rotation/cancel)|configuration-receipts|family/assisted-execution-reports|observation-settings|usage-observations|configurations\\?after=[0-9]{1,16}&limit=10)")))
        val connection = open(URI("$root/device-api/$path").toURL())
        val expired = AtomicBoolean(false)
        val watchdog = deadlines.schedule({ expired.set(true); connection.disconnect() }, requestTimeoutMillis, TimeUnit.MILLISECONDS)
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.useCaches = false
            connection.requestMethod = method
            connection.setRequestProperty("Authorization", "Bearer $credential")
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) {
                val bytes = JSONObjectUtils.toJSONString(body).toByteArray(Charsets.UTF_8)
                require(bytes.size <= if(path == "usage-observations") 1048576 else 65536)
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.setFixedLengthStreamingMode(bytes.size)
                connection.outputStream.use { it.write(bytes) }
            }
            check(!expired.get() && !Thread.currentThread().isInterrupted)
            val status = connection.responseCode
            check(!expired.get() && !Thread.currentThread().isInterrupted)
            if (status !in 200..299) {
                val mediaType = connection.contentType?.substringBefore(';')?.trim()?.lowercase()
                if(status !in 400..499 || mediaType !in setOf("application/json", "application/problem+json"))
                    return BackgroundResponse(status)
                val bytes = java.io.ByteArrayOutputStream()
                connection.errorStream?.use { input ->
                    val buffer = ByteArray(4096)
                    while(true) {
                        check(!expired.get() && !Thread.currentThread().isInterrupted)
                        val count = input.read(buffer)
                        if(count < 0) break
                        require(bytes.size() + count <= 65536)
                        bytes.write(buffer, 0, count)
                    }
                }
                val code = try {
                    val error = JSONObjectUtils.parse(bytes.toString("UTF-8"))
                    require(if(mediaType == "application/problem+json") integer(error, "status") == status.toLong()
                        else error["status"] == null || integer(error, "status") == status.toLong())
                    error["errorCode"]
                } catch (_: Exception) { null }
                return BackgroundResponse(status, if(code in setOf("OBSERVATION_NOT_AUTHORIZED", "OBSERVATION_AUTHORIZATION_CHANGED"))
                    mapOf("errorCode" to code) else emptyMap())
            }
            if (status == 204) return BackgroundResponse(204)
            val limit = if (path.startsWith("configurations?")) 2097152 else 65536
            require(connection.contentLengthLong <= limit)
            require(connection.contentType?.substringBefore(';')?.trim()?.lowercase() == "application/json")
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(10)
            val bytes = java.io.ByteArrayOutputStream()
            connection.inputStream.use { input ->
                val buffer = ByteArray(8192)
                while (true) {
                    check(!expired.get() && System.nanoTime() < deadline && !Thread.currentThread().isInterrupted)
                    val count = input.read(buffer)
                    if (count < 0) break
                    require(bytes.size() + count <= limit)
                    bytes.write(buffer, 0, count)
                }
            }
            return BackgroundResponse(status, JSONObjectUtils.parse(bytes.toString("UTF-8")))
        } finally { watchdog.cancel(false); connection.disconnect() }
    }
    companion object {
        private val deadlines = java.util.concurrent.ScheduledThreadPoolExecutor(1) { task ->
            Thread(task, "family-http-deadlines").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }
    }
}

