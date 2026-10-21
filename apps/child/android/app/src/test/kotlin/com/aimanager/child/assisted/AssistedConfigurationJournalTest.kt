package com.aimanager.child.assisted

import com.nimbusds.jose.*
import com.nimbusds.jose.crypto.ECDSASigner
import com.nimbusds.jose.jwk.*
import com.nimbusds.jose.jwk.gen.ECKeyGenerator
import com.nimbusds.jose.util.JSONObjectUtils
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class AssistedConfigurationJournalTest {
    private val key = ECKeyGenerator(Curve.P_256).keyID("pinned").generate()
    private val now = 1792026000000L
    private val scope = AssistedScope("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333")
    private val policy = "44444444-4444-4444-8444-444444444444"
    private val delivery = "66666666-6666-4666-8666-666666666666"
    private val verifier get() = AssistedConfigurationVerifier("issuer", JWKSet(key.toPublicJWK()).toString())
    private class Memory(var value: String? = null) : BackgroundJournalPersistence {
        override fun read() = value
        override fun write(value: String?) { this.value = value }
    }
    private fun gate() = DurableIdentityGate(object : IdentityPersistence {
        var raw: String? = "current-registration"
        override fun read() = raw
        override fun write(value: String?) { raw = value }
    })
    private fun signed(sequence: Long = 2, exception: Long? = null, generic: Boolean = false,
        signingKey: ECKey = key, changes: Map<String, Any?> = emptyMap()): String {
        val doc = mapOf("name" to "Family", "rules" to emptyList<Any>(), "applications" to emptyList<Any>(),
            "schedules" to emptyList<Any>(), "protectedPackageExemptions" to emptyList<Any>()) + if(generic) emptyMap()
            else mapOf("familyAssistance" to mapOf("schemaVersion" to 1, "mode" to "FAMILY_ASSISTED", "enabled" to true,
                "dailyAllowanceSeconds" to 3600, "timeZoneId" to "Asia/Shanghai", "meteredPackages" to listOf("com.example.game"),
                "allowedWindows" to emptyList<Any>(), "validUntil" to now + 86400000L, "exceptionUntil" to exception))
        val body = mapOf("schemaVersion" to 1, "issuer" to "issuer", "purpose" to "CONFIGURATION", "mode" to "CONFIGURE_ONLY",
            "tenantId" to scope.tenantId, "deviceId" to scope.deviceId, "registrationId" to scope.registrationId,
            "policyId" to policy, "versionId" to "55555555-5555-4555-8555-55555555555${sequence % 10}",
            "deliveryId" to delivery, "sourceSequence" to sequence, "cursor" to sequence,
            "issuedAt" to now - 1000, "deliveryExpiresAt" to now + 60000L, "effectiveUntil" to null,
            "action" to "UPSERT_CONFIGURATION", "document" to doc) + changes
        return JWSObject(JWSHeader.Builder(JWSAlgorithm.ES256).keyID("pinned")
            .type(JOSEObjectType("aimanager-configuration+jws")).build(), Payload(body)).apply { sign(ECDSASigner(signingKey)) }.serialize()
    }
    private fun page(compact: String, cursor: Long = 2, more: Boolean = false) = BackgroundResponse(200, mapOf(
        "serverTime" to now, "nextAfter" to cursor, "hasMore" to more,
        "items" to listOf(mapOf("id" to delivery, "cursor" to cursor, "compactJws" to compact,
            "deliveryExpiresAt" to now + 60000L, "state" to "SERVED"))))
    private fun ack(body: Map<String, Any?>?) = BackgroundResponse(200, mapOf("id" to body!!["receiptId"],
        "state" to "DEVICE_REPORTED_STORED", "historical" to false, "receivedAt" to now,
        "evidenceStatus" to "DEVICE_REPORT_NOT_EXECUTION"))
    @Test fun signedConfigurationAndReceiptAreDurableBeforeAckAndApply() {
        val memory = Memory()
        val gate = gate()
        val compact = signed(exception = now + 5000)
        var applied = false
        var acknowledged = false
        AssistedConfigurationJournal(gate, memory, BackgroundTransport { method, _, _, body ->
            if(method == "GET") page(compact) else {
                assertTrue(memory.value!!.contains(compact))
                assertTrue(applied)
                acknowledged = true
                ack(body)
            }
        }, verifier, { current, values -> assertEquals(scope, current); assertEquals(listOf(compact), values); applied = true }, { now })
            .synchronize(gate.lease(), scope, "a".repeat(43))
        assertTrue("native synchronization must persist and ACK", acknowledged)
        assertEquals(2L, JSONObjectUtils.parse(memory.value)["cursor"])
        assertTrue((JSONObjectUtils.parse(memory.value)["receipts"] as List<*>).isEmpty())
    }
    @Test fun droppedAckReplaysOriginalReceiptAfterReconstruction() {
        val memory = Memory()
        val gate = gate()
        var receipt: Any? = null
        val compact = signed()
        try { AssistedConfigurationJournal(gate, memory, BackgroundTransport { method, _, _, body ->
            if(method == "GET") page(compact) else { receipt = body!!["receiptId"]; throw IllegalStateException("response lost") }
        }, verifier, { _, _ -> }, { now }).synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { }
        assertNotNull(receipt)
        var replayed = false
        AssistedConfigurationJournal(gate, memory, BackgroundTransport { method, _, _, body ->
            if(method == "POST") { assertEquals(receipt, body!!["receiptId"]); replayed = true; ack(body) }
            else BackgroundResponse(200, mapOf("serverTime" to now, "nextAfter" to 2L, "hasMore" to false, "items" to emptyList<Any>()))
        }, verifier, { _, _ -> }, { now }).synchronize(gate.lease(), scope, "a".repeat(43))
        assertTrue(replayed)
    }
    @Test fun forgedOrTransportMismatchedPageCannotAdvanceCursorOrApply() {
        for(compact in listOf(signed(signingKey = ECKeyGenerator(Curve.P_256).generate()),
            signed(changes = mapOf("registrationId" to scope.deviceId)), signed(changes = mapOf("cursor" to 3L)))) {
            val memory = Memory()
            val gate = gate()
            var applied = false
            try { AssistedConfigurationJournal(gate, memory, BackgroundTransport { _, _, _, _ -> page(compact) }, verifier,
                { _, _ -> applied = true }, { now }).synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { }
            assertNull(memory.value)
            assertFalse(applied)
        }
    }
    @Test fun cleanupWhilePullIsInFlightCannotRepopulateCache() {
        val memory = Memory()
        val gate = gate()
        val lease = gate.lease()
        var applied = false
        try { AssistedConfigurationJournal(gate, memory, BackgroundTransport { _, _, _, _ ->
            gate.compareAndSet(lease.raw, null); page(signed())
        }, verifier, { _, _ -> applied = true }, { now }).synchronize(lease, scope, "a".repeat(43)) } catch (_: Exception) { }
        assertNull(memory.value)
        assertFalse(applied)
    }
    @Test fun ordinaryInstitutionalConfigurationIsStoredWithoutBecomingFamilyAuthority() {
        val memory = Memory()
        val gate = gate()
        val compact = signed(generic = true)
        var acked = false
        var family = false
        AssistedConfigurationJournal(gate, memory, BackgroundTransport { method, _, _, body ->
            if(method == "GET") page(compact) else { acked = true; ack(body) }
        }, verifier, { _, values -> family = values.any { verifier.verify(it, scope, now, true) != null } }, { now })
            .synchronize(gate.lease(), scope, "a".repeat(43))
        assertTrue(acked)
        assertFalse(family)
        assertEquals(2L, JSONObjectUtils.parse(memory.value)["cursor"])
    }
    @Test fun cancelledCoordinatorCannotOverwriteNewerJournalAfterAnOldPullReturns() {
        val memory = Memory()
        val gate = gate()
        val pending = CountDownLatch(1)
        val release = CountDownLatch(1)
        var latestApplied = 0L
        val old = AssistedConfigurationJournal(gate, memory, BackgroundTransport { method, _, _, body ->
            if(method == "GET") { pending.countDown(); check(release.await(5, TimeUnit.SECONDS)); page(signed()) }
            else ack(body)
        }, verifier, { _, values -> latestApplied = integer(verifier.verifyEnvelope(values.single(), scope, now, true)!!, "sourceSequence") }, { now })
        val pool = Executors.newSingleThreadExecutor()
        try {
            val result = pool.submit { try { old.synchronize(gate.lease(), scope, "a".repeat(43)) } catch (_: Exception) { } }
            assertTrue(pending.await(5, TimeUnit.SECONDS))
            AssistedConfigurationJournal(gate, memory, BackgroundTransport { method, _, _, body ->
                if(method == "GET") page(signed(3), 3) else ack(body)
            }, verifier, { _, _ -> latestApplied = 3 }, { now }).synchronize(gate.lease(), scope, "a".repeat(43))
            release.countDown(); result.get(5, TimeUnit.SECONDS)
            assertEquals(3L, JSONObjectUtils.parse(memory.value)["cursor"])
            assertEquals(3L, latestApplied)
        } finally { release.countDown(); pool.shutdownNow() }
    }
}
