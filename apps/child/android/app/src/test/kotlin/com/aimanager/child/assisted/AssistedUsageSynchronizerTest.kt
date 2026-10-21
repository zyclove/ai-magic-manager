package com.aimanager.child.assisted

import com.nimbusds.jose.util.JSONObjectUtils
import org.junit.Assert.*
import org.junit.Test

class AssistedUsageSynchronizerTest {
    private val now = 1792026000000L
    private val scope = AssistedScope("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333")
    private class Journal : UsageJournalStore {
        var value: String? = null
        var conflict = false
        override fun read() = value
        override fun compareAndSet(expected: String?, replacement: String?): Boolean {
            if(conflict || expected != value) return false
            value = replacement; return true
        }
    }
    private fun gate() = DurableIdentityGate(object : IdentityPersistence {
        var value: String? = "identity"
        override fun read() = value
        override fun write(value: String?) { this.value = value }
    })
    private inner class Source : NativeUsageSource {
        var granted = true
        var reads = 0
        var onRead: () -> Unit = { }
        override fun inspect() = NativeUsageFacts(granted, true, true, "PRIMARY")
        override fun sample(): Map<String, Any?> {
            reads++
            onRead()
            return mapOf("queryStart" to now - 3600000, "queryEnd" to now, "observedAt" to now,
                "timeZone" to "Asia/Shanghai", "profile" to "PRIMARY", "applications" to listOf(mapOf(
                    "packageName" to "com.example.game", "displayName" to "Game", "firstTimeStamp" to now - 3600000,
                    "lastTimeStamp" to now, "foregroundMillis" to 120000L)))
        }
    }
    private fun authorization(enabled: Boolean = true, version: Long = 2) = BackgroundResponse(200, mapOf(
        "deviceId" to scope.deviceId, "registrationId" to scope.registrationId, "version" to version,
        "inventoryEnabled" to false, "usageEnabled" to enabled, "updatedAt" to now))
    private fun ack(body: Map<String, Any?>?) = BackgroundResponse(200, mapOf("registrationId" to scope.registrationId,
        "reportId" to body!!["reportId"], "sequence" to body["sequence"], "receivedAt" to now))
    @Test fun authorizationAndOriginalBatchAreDurableBeforeCollectionAndUpload() {
        val journal = Journal()
        val source = Source()
        source.onRead = { assertEquals(2L, (JSONObjectUtils.parse(journal.value)["authorization"] as Map<*, *>)["version"]) }
        val gate = gate()
        var posted = false
        AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, path, _, body ->
            if(method == "GET") authorization() else {
                assertEquals("usage-observations", path)
                assertEquals(body, JSONObjectUtils.parse(journal.value)["pendingUsage"])
                assertEquals(1L, body!!["sequence"])
                assertEquals(2L, body["authorizationVersion"])
                posted = true; ack(body)
            }
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43))
        assertTrue("background usage must upload", posted)
        assertEquals(1, source.reads)
        assertNull(JSONObjectUtils.parse(journal.value)["pendingUsage"])
        assertEquals(1L, JSONObjectUtils.parse(journal.value)["usageSequence"])
    }
    @Test fun lostUploadResponseReplaysExactUuidSequenceAndWindowWithoutAnotherQuery() {
        val journal = Journal(); val source = Source(); val gate = gate()
        var body: Map<String, Any?>? = null
        try { AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, payload ->
            if(method == "GET") authorization() else { body = payload; throw IllegalStateException("offline") }
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { }
        assertNotNull(body)
        AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, payload ->
            if(method == "GET") authorization() else { assertEquals(body, payload); ack(payload) }
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43))
        assertEquals(1, source.reads)
    }
    @Test fun revokedUsageOrDifferentRegistrationNeverQueriesSensitiveStats() {
        for(response in listOf(authorization(false), BackgroundResponse(200, authorization().body + mapOf("registrationId" to scope.deviceId)))) {
            val journal = Journal(); val source = Source(); val gate = gate()
            try { AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { _, _, _, _ -> response }, { now })
                .synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { }
            assertEquals(0, source.reads)
        }
    }
    @Test fun successfulPeriodPreventsRepeatedDailyBucketsOnEveryPoll() {
        val journal = Journal(); val source = Source(); val gate = gate()
        val sync = AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, body ->
            if(method == "GET") authorization() else ack(body)
        }, { now })
        sync.synchronize(gate.lease(), scope, "a".repeat(43))
        sync.synchronize(gate.lease(), scope, "a".repeat(43))
        assertEquals(1, source.reads)
    }
    @Test fun foregroundJournalCompetitionCannotOverwriteOrSendAnotherSequence() {
        val journal = Journal(); val source = Source(); val gate = gate()
        var posts = 0
        try { AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, body ->
            if(method == "GET") { journal.conflict = true; authorization() } else { posts++; ack(body) }
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { }
        assertEquals(0, posts)
        assertEquals(0, source.reads)
    }
    @Test fun cleanupDuringSampleCannotPersistOrUploadOldUsage() {
        val journal = Journal(); val gate = gate(); val lease = gate.lease()
        var posts = 0
        val source = object : NativeUsageSource {
            override fun inspect() = NativeUsageFacts(true, true, true, "PRIMARY")
            override fun sample(): Map<String, Any?> { gate.compareAndSet(lease.raw, null); return Source().sample() }
        }
        try { AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, body ->
            if(method == "GET") authorization() else { posts++; ack(body) }
        }, { now }).synchronize(lease, scope, "a".repeat(43)) } catch (_: Exception) { }
        assertEquals(0, posts)
        assertTrue(journal.value == null || JSONObjectUtils.parse(journal.value)["pendingUsage"] == null)
    }
    @Test fun usageRevocationDropsPendingBatchWithoutResettingItsSequence() {
        val journal = Journal(); val source = Source(); val gate = gate()
        try { AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, _ ->
            if(method == "GET") authorization() else throw IllegalStateException("response lost")
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { }
        assertNotNull(JSONObjectUtils.parse(journal.value)["pendingUsage"])
        AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { _, _, _, _ -> authorization(false, 3) }, { now })
            .synchronize(gate.lease(), scope, "a".repeat(43))
        val state = JSONObjectUtils.parse(journal.value)
        assertEquals(1L, state["usageSequence"])
        assertNull(state["pendingUsage"])
        assertEquals(1, source.reads)
    }
    @Test fun systemPermissionRevocationAfterQueryDropsBatchBeforeHttp() {
        val journal = Journal(); val source = Source(); val gate = gate()
        var posts = 0
        source.onRead = { source.granted = false }
        AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, body ->
            if(method == "GET") authorization() else { posts++; ack(body) }
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43))
        assertEquals(0, posts)
        assertNull(JSONObjectUtils.parse(journal.value)["pendingUsage"])
        assertEquals(1L, JSONObjectUtils.parse(journal.value)["usageSequence"])
    }
    @Test fun wrongAckBindingRetainsOriginalBatchForRecovery() {
        val journal = Journal(); val source = Source(); val gate = gate()
        try { AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, body ->
            if(method == "GET") authorization() else BackgroundResponse(200, ack(body).body + mapOf("registrationId" to scope.deviceId))
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { }
        val state = JSONObjectUtils.parse(journal.value)
        assertNotNull(state["pendingUsage"])
        assertNull(state["lastUsageAt"])
    }
    @Test fun foregroundCommitWhileAckIsInFlightCannotBeOverwritten() {
        val journal = Journal(); val source = Source(); val gate = gate()
        var foreground: String? = null
        try { AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, body ->
            if(method == "GET") authorization() else {
                val newer = JSONObjectUtils.parse(journal.value)
                newer["permissionSequence"] = 7L
                foreground = JSONObjectUtils.toJSONString(newer)
                journal.value = foreground
                ack(body)
            }
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { }
        assertEquals(foreground, journal.value)
        assertEquals(7L, JSONObjectUtils.parse(journal.value)["permissionSequence"])
        assertNotNull(JSONObjectUtils.parse(journal.value)["pendingUsage"])
    }
    @Test fun feature403ForgetsUsageIntentAndKeepsIdentityForOtherFeatures() {
        val journal = Journal(); val source = Source(); val gate = gate(); val original = gate.read()
        AssistedUsageSynchronizer(gate, journal, source, BackgroundTransport { method, _, _, _ ->
            if(method == "GET") authorization() else BackgroundResponse(403, mapOf("errorCode" to "OBSERVATION_NOT_AUTHORIZED"))
        }, { now }).synchronize(gate.lease(), scope, "a".repeat(43))
        assertEquals(original, gate.read())
        assertNull(JSONObjectUtils.parse(journal.value)["pendingUsage"])
        assertNull(JSONObjectUtils.parse(journal.value)["authorization"])
        assertEquals(1L, JSONObjectUtils.parse(journal.value)["usageSequence"])
    }
}
