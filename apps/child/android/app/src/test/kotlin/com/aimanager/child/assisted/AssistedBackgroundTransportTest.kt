package com.aimanager.child.assisted

import org.junit.Assert.*
import org.junit.Test
import java.net.URL
import java.io.*
import java.security.Principal
import java.security.cert.Certificate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

class AssistedBackgroundTransportTest {
    private class Connection(url: URL, var status: Int = 200, var response: String = "{}") : HttpsURLConnection(url) {
        var disconnected = false
        var blockingWrite = false
        var type = "application/json; charset=utf-8"
        val released = CountDownLatch(1)
        val output = ByteArrayOutputStream()
        override fun connect() { }
        override fun disconnect() { disconnected = true; released.countDown() }
        override fun usingProxy() = false
        override fun getCipherSuite() = "TLS_TEST"
        override fun getLocalCertificates(): Array<Certificate>? = null
        override fun getServerCertificates(): Array<Certificate> = emptyArray()
        override fun getPeerPrincipal(): Principal = Principal { "installed.example" }
        override fun getLocalPrincipal(): Principal? = null
        override fun getResponseCode() = status
        override fun getContentType() = type
        override fun getContentLengthLong() = -1L
        override fun getInputStream() = ByteArrayInputStream(response.toByteArray())
        override fun getErrorStream() = ByteArrayInputStream(response.toByteArray())
        override fun getOutputStream(): OutputStream = if(!blockingWrite) output else object : OutputStream() {
            override fun write(value: Int) { released.await(1, TimeUnit.SECONDS) }
        }
    }
    @Test fun installedOriginAndFixedRouteControlEveryCredentialRequestWithoutRedirects() {
        val connection = Connection(URL("https://installed.example/api/v1/device-api/heartbeats"))
        var requested: URL? = null
        InstalledBackgroundTransport("https://installed.example/api/v1", { requested = it; connection })
            .request("POST", "heartbeats", "a".repeat(43), mapOf("sequence" to 1))
        assertEquals("https://installed.example/api/v1/device-api/heartbeats", requested.toString())
        assertEquals("Bearer ${"a".repeat(43)}", connection.getRequestProperty("Authorization"))
        assertFalse(connection.instanceFollowRedirects)
        assertTrue(connection.disconnected)
        for(root in listOf("http://localhost/api/v1", "https://user@installed.example/api/v1", "https://installed.example/api/v1?endpoint=evil",
            "https://installed.example/api/v1#evil", "https://installed.example/../api/v1")) {
            try { InstalledBackgroundTransport(root); fail("invalid origin") } catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun redirectsAreReturnedWithoutFollowingAndOversizedBodiesAreRejected() {
        val redirect = Connection(URL("https://installed.example"), 302)
        assertEquals(302, InstalledBackgroundTransport("https://installed.example/api/v1", { redirect })
            .request("GET", "configurations?after=0&limit=10", "a".repeat(43), null).status)
        val large = Connection(URL("https://installed.example"), 200, " ".repeat(65537))
        try { InstalledBackgroundTransport("https://installed.example/api/v1", { large })
            .request("POST", "heartbeats", "a".repeat(43), emptyMap()); fail("oversized response") }
        catch (_: IllegalArgumentException) { }
        assertTrue(large.disconnected)
    }
    @Test fun writeTimeoutDisconnectsAndRejectsUnknownPostOutcome() {
        val connection = Connection(URL("https://installed.example"), 204).apply { blockingWrite = true }
        val started = System.nanoTime()
        var failed = false
        try { InstalledBackgroundTransport("https://installed.example/api/v1", { connection }, 50)
            .request("POST", "credentials/activate", "a".repeat(43), emptyMap()) }
        catch (_: Exception) { failed = true }
        assertTrue("write timeout must reject a possibly committed POST", failed)
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 500)
        assertTrue(connection.disconnected)
    }
    @Test fun springProblemJsonFeatureDenialDoesNotBecomeAnAuthenticationDenial() {
        val connection = Connection(URL("https://installed.example"), 403,
            "{\"type\":\"about:blank\",\"title\":\"Forbidden\",\"status\":403,\"errorCode\":\"OBSERVATION_NOT_AUTHORIZED\"}")
            .apply { type = "application/problem+json" }
        val response = InstalledBackgroundTransport("https://installed.example/api/v1", { connection })
            .request("POST", "usage-observations", "a".repeat(43), emptyMap())
        assertEquals("OBSERVATION_NOT_AUTHORIZED", response.body["errorCode"])
    }
    @Test fun observationFeatureRejectionKeepsOnlyItsWhitelistedCode() {
        val connection = Connection(URL("https://installed.example"), 403,
            "{\"errorCode\":\"OBSERVATION_NOT_AUTHORIZED\",\"message\":\"private server text\"}")
        val response = InstalledBackgroundTransport("https://installed.example/api/v1", { connection })
            .request("POST", "heartbeats", "a".repeat(43), emptyMap())
        assertEquals(mapOf("errorCode" to "OBSERVATION_NOT_AUTHORIZED"), response.body)
        assertTrue(connection.disconnected)
    }
}
