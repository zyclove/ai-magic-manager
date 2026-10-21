package com.aimanager.child.assisted

import com.nimbusds.jose.util.JSONObjectUtils
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class AssistedBackgroundSyncTest {
    private val now = 1792026000000L
    private val root = "https://installed.example/api/v1"
    private val tenant = "11111111-1111-4111-8111-111111111111"
    private val device = "22222222-2222-4222-8222-222222222222"
    private val registration = "33333333-3333-4333-8333-333333333333"
    private val old = "a".repeat(43)
    private val next = "b".repeat(43)
    private fun record(changes: Map<String, Any?> = emptyMap()) = JSONObjectUtils.toJSONString(mapOf<String, Any?>(
        "schemaVersion" to 1, "kind" to "DEVICE_IDENTITY", "apiRoot" to root,
        "tenantId" to tenant, "deviceId" to device, "registrationId" to registration,
        "phase" to "active", "credential" to old, "credentialExpiresAt" to now + 172800000,
        "observedAt" to now - 1000, "heartbeatSequence" to 0
    ) + changes)
    private class Memory(var value: String?) : IdentityPersistence {
        var failAfterWrite = false
        override fun read() = value
        override fun write(value: String?) { this.value = value; if (failAfterWrite) throw IllegalStateException("lost completion") }
    }
    private class Runtime : BackgroundRuntime {
        var cleared = false
        var value: Map<String, Any?> = emptyMap()
        override fun clear() { cleared = true }
        override fun snapshot() = value
    }
    private class Configurations : BackgroundConfigurations {
        var syncs = 0
        var cleared = false
        override fun synchronize(identity: IdentityLease, scope: AssistedScope, credential: String) { syncs++ }
        override fun clear() { cleared = true }
    }
    private fun sync(memory: Memory, transport: BackgroundTransport, runtime: Runtime = Runtime(),
        configurations: Configurations = Configurations(), gate: DurableIdentityGate = DurableIdentityGate(memory)) =
        AssistedBackgroundSync(gate, transport, configurations, runtime, root) { now }
    private fun heartbeat(body: Map<String, Any?>?) = BackgroundResponse(200, mapOf(
        "registrationId" to registration, "sequence" to body!!["sequence"], "receivedAt" to now))

    @Test fun heartbeatPersistsOriginalIntentBeforeSendingAndCommitsExactAcknowledgement() {
        val memory = Memory(record())
        var sent = false
        sync(memory, BackgroundTransport { _, path, token, body ->
            if (path == "heartbeats") {
                assertEquals(old, token)
                assertEquals(body, JSONObjectUtils.parse(memory.value)["pendingHeartbeat"])
                sent = true
                heartbeat(body)
            } else BackgroundResponse(200)
        }).cycle()
        assertTrue("background heartbeat must run without Flutter", sent)
        val state = JSONObjectUtils.parse(memory.value)
        assertEquals(1L, state["heartbeatSequence"])
        assertEquals(now, state["lastHeartbeatAt"])
        assertFalse(state.containsKey("pendingHeartbeat"))
    }
    @Test fun lostHeartbeatResponseReplaysTheSameDurableSequenceAfterRestart() {
        val memory = Memory(record())
        sync(memory, BackgroundTransport { _, _, _, _ -> throw IllegalStateException("offline") }).cycle()
        assertNotNull(JSONObjectUtils.parse(memory.value)["pendingHeartbeat"])
        val original = JSONObjectUtils.parse(memory.value)["pendingHeartbeat"]
        sync(memory, BackgroundTransport { _, path, _, body ->
            if (path == "heartbeats") { assertEquals(original, body); heartbeat(body) } else BackgroundResponse(200)
        }).cycle()
        assertEquals(1L, JSONObjectUtils.parse(memory.value)["heartbeatSequence"])
    }
    @Test fun imminentExpiryRotatesThenActivatesBeforeAnyOrdinaryRequest() {
        val memory = Memory(record(mapOf("credentialExpiresAt" to now + 60000)))
        val calls = mutableListOf<String>()
        sync(memory, BackgroundTransport { _, path, token, body ->
            calls.add(path)
            when(path) {
                "credentials/rotate" -> { assertEquals("rotationRequested", JSONObjectUtils.parse(memory.value)["phase"])
                    BackgroundResponse(200, mapOf("credentialId" to device, "credential" to next,
                        "expiresAt" to now + 604800000, "activateBefore" to now + 30000)) }
                "credentials/activate" -> { assertEquals(next, token)
                    assertEquals("activationUncertain", JSONObjectUtils.parse(memory.value)["phase"]); BackgroundResponse(204) }
                "heartbeats" -> { assertEquals(next, token); heartbeat(body) }
                else -> BackgroundResponse(200)
            }
        }).cycle()
        assertEquals(listOf("credentials/rotate", "credentials/activate", "heartbeats"), calls)
        assertEquals(next, JSONObjectUtils.parse(memory.value)["credential"])
        assertEquals("active", JSONObjectUtils.parse(memory.value)["phase"])
    }
    @Test fun lostRotateResponseRecoversByCancellingBeforeRequestingAnotherSecret() {
        val memory = Memory(record(mapOf("phase" to "rotationRequested", "credentialExpiresAt" to now + 60000)))
        val paths = mutableListOf<String>()
        sync(memory, BackgroundTransport { _, path, _, _ -> paths.add(path); BackgroundResponse(204) }).cycle()
        assertEquals(listOf("credentials/rotation/cancel"), paths)
        assertEquals("active", JSONObjectUtils.parse(memory.value)["phase"])
    }
    @Test fun activationResponseLossRetainsPendingSecretAndReplaysItAfterItsOriginalWindow() {
        val pending = mapOf("credentialId" to device, "credential" to next,
            "expiresAt" to now + 604800000, "activateBefore" to now - 1000)
        val memory = Memory(record(mapOf("phase" to "activationUncertain", "pendingCredential" to pending)))
        var activated = false
        sync(memory, BackgroundTransport { _, path, token, body ->
            if(path == "credentials/activate") { activated = true; assertEquals(next, token); BackgroundResponse(204) }
            else heartbeat(body)
        }).cycle()
        assertTrue(activated)
        assertEquals(next, JSONObjectUtils.parse(memory.value)["credential"])
    }
    @Test fun expiredUnactivatedWindowCancelsInsteadOfExtendingDeadline() {
        val pending = mapOf("credentialId" to device, "credential" to next,
            "expiresAt" to now + 604800000, "activateBefore" to now - 1)
        val memory = Memory(record(mapOf("phase" to "rotationPending", "pendingCredential" to pending)))
        val calls = mutableListOf<String>()
        sync(memory, BackgroundTransport { _, path, _, _ -> calls.add(path); BackgroundResponse(204) }).cycle()
        assertEquals(listOf("credentials/rotation/cancel"), calls)
        assertFalse(JSONObjectUtils.parse(memory.value).containsKey("pendingCredential"))
    }
    @Test fun cleanupDuringHeartbeatCannotBeResurrectedByOldAcknowledgement() {
        val memory = Memory(record())
        val gate = DurableIdentityGate(memory)
        val cleanup = record(mapOf("phase" to "cleanupPending", "credential" to null, "authenticationBlocked" to true))
        sync(memory, BackgroundTransport { _, _, _, body ->
            assertTrue(gate.compareAndSet(memory.value, cleanup)); heartbeat(body)
        }, gate = gate).cycle()
        assertEquals(cleanup, memory.value)
    }
    @Test fun old401AfterRotationCannotBlockTheNewCredentialOrClearItsRuntime() {
        val memory = Memory(record())
        val gate = DurableIdentityGate(memory)
        val current = record(mapOf("credential" to next))
        val runtime = Runtime()
        sync(memory, BackgroundTransport { _, _, _, _ ->
            gate.compareAndSet(memory.value, current); BackgroundResponse(401)
        }, runtime, gate = gate).cycle()
        assertEquals(current, memory.value)
        assertFalse(runtime.cleared)
    }
    @Test fun authentication401DurablyBlocksCredentialAndClearsAssistance() {
        val memory = Memory(record())
        val runtime = Runtime()
        val configs = Configurations()
        sync(memory, BackgroundTransport { _, _, _, _ -> BackgroundResponse(401) }, runtime, configs).cycle()
        assertEquals(true, JSONObjectUtils.parse(memory.value)["authenticationBlocked"])
        assertTrue(runtime.cleared)
        assertTrue(configs.cleared)
    }
    @Test fun family403DoesNotBlockValidDeviceCredential() {
        val memory = Memory(record(mapOf("lastHeartbeatAt" to now)))
        val runtime = Runtime().apply { value = mapOf("tenantId" to tenant, "deviceId" to device,
            "registrationId" to registration, "policyId" to device, "versionId" to tenant,
            "sourceSequence" to 1L, "reportSequence" to 1L, "observedAt" to now,
            "systemEnforced" to false) }
        sync(memory, BackgroundTransport { _, _, _, _ -> BackgroundResponse(403) }, runtime).cycle()
        assertNotEquals(true, JSONObjectUtils.parse(memory.value)["authenticationBlocked"])
        assertFalse(runtime.cleared)
    }
    @Test fun ordinaryHeartbeat403BlocksInactiveRegistrationAndClearsRuntime() {
        val memory = Memory(record())
        val runtime = Runtime()
        sync(memory, BackgroundTransport { _, _, _, _ -> BackgroundResponse(403) }, runtime).cycle()
        assertEquals(true, JSONObjectUtils.parse(memory.value)["authenticationBlocked"])
        assertTrue(runtime.cleared)
    }
    @Test fun identityReplacementNotifiesBeforeAnyOlderLeaseCanApply() {
        val memory = Memory(record())
        var changed = false
        val gate = DurableIdentityGate(memory) { _, after -> changed = after == null }
        val lease = gate.lease()
        gate.compareAndSet(lease.raw, null)
        assertTrue(changed)
        assertFalse(gate.current(lease) { fail() })
    }
    @Test fun differentInstalledOriginOrCleanupOrExpiredIdentityNeverSendsNetwork() {
        for(changes in listOf(mapOf("apiRoot" to "https://attacker.example/api/v1"),
            mapOf("phase" to "cleanupPending"), mapOf("authenticationBlocked" to true),
            mapOf("credentialExpiresAt" to now), mapOf("observedAt" to now + 1))) {
            var calls = 0
            sync(Memory(record(changes)), BackgroundTransport { _, _, _, _ -> calls++; BackgroundResponse(200) }).cycle()
            assertEquals(0, calls)
        }
    }
    @Test fun epochFenceRejectsAbaAndDurabilityFailureInvalidatesOldLease() {
        val memory = Memory(record())
        val gate = DurableIdentityGate(memory)
        val lease = gate.lease()
        assertTrue(gate.compareAndSet(lease.raw, null))
        assertTrue(gate.compareAndSet(null, lease.raw))
        assertFalse(gate.current(lease) { fail("stale action") })
        val beforeFailure = gate.lease()
        memory.failAfterWrite = true
        try { gate.compareAndSet(beforeFailure.raw, record(mapOf("credential" to next))); fail() } catch (_: IllegalStateException) { }
        assertFalse(gate.current(beforeFailure) { fail("uncertain action") })
    }
    @Test fun concurrentCompareAndSetOnlyOneWriterWins() {
        val memory = Memory(record())
        val gate = DurableIdentityGate(memory)
        val original = memory.value
        val ready = CountDownLatch(2)
        val start = CountDownLatch(1)
        val pool = Executors.newFixedThreadPool(2)
        try {
            val results = listOf("x", "y").map { value -> pool.submit<Boolean> {
                ready.countDown(); start.await(); gate.compareAndSet(original, value)
            } }
            assertTrue(ready.await(5, TimeUnit.SECONDS)); start.countDown()
            assertEquals(1, results.count { it.get(5, TimeUnit.SECONDS) })
        } finally { pool.shutdownNow() }
    }
    @Test fun serviceCanUseOnlyAConfirmedCachedLeaseAndUncertainWritesSuspendIt() {
        val memory = Memory(record())
        val gate = DurableIdentityGate(memory)
        assertFalse(gate.cached { fail("storage has not been read") })
        gate.lease()
        assertTrue(gate.cached { assertEquals(memory.value, it.raw) })
        memory.failAfterWrite = true
        try { gate.compareAndSet(memory.value, null) } catch (_: Exception) { }
        assertFalse(gate.cached { fail("storage outcome uncertain") })
    }
    @Test fun shortLivedServerCredentialsDoNotRotateOnEveryBackgroundPoll() {
        val memory = Memory(record(mapOf("credentialExpiresAt" to now + 60000)))
        var rotations = 0
        val sync = sync(memory, BackgroundTransport { _, path, _, body -> when(path) {
            "credentials/rotate" -> { rotations++; BackgroundResponse(200, mapOf("credentialId" to device,
                "credential" to next, "expiresAt" to now + 3600000, "activateBefore" to now + 30000)) }
            "credentials/activate" -> BackgroundResponse(204)
            else -> heartbeat(body)
        } })
        sync.cycle(); sync.cycle()
        assertEquals(1, rotations)
    }
}
