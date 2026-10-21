package com.aimanager.child.assisted

import com.nimbusds.jose.JOSEObjectType
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.JWSObject
import com.nimbusds.jose.Payload
import com.nimbusds.jose.crypto.ECDSASigner
import com.nimbusds.jose.jwk.JWKSet
import com.nimbusds.jose.jwk.Curve
import com.nimbusds.jose.jwk.gen.ECKeyGenerator
import org.junit.Assert.*
import org.junit.Test

class SignedAssistedConfigurationTest {
    private val key = ECKeyGenerator(Curve.P_256).keyID("test-installation-key").generate()
    private val scope = AssistedScope("11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333")
    private val now = 1792026000000L
    private val verifier get() = AssistedConfigurationVerifier("test-issuer", JWKSet(key.toPublicJWK()).toString())
    private fun document(extension: Map<String, Any?> = assistance()) = mapOf("name" to "Family use",
        "rules" to emptyList<Any>(), "applications" to emptyList<Any>(), "schedules" to emptyList<Any>(),
        "protectedPackageExemptions" to emptyList<Any>(), "familyAssistance" to extension)
    private fun assistance() = mapOf("schemaVersion" to 1, "mode" to "FAMILY_ASSISTED", "enabled" to true,
        "dailyAllowanceSeconds" to 3600, "timeZoneId" to "Asia/Shanghai",
        "meteredPackages" to listOf("com.example.game"), "allowedWindows" to emptyList<Any>(),
        "validUntil" to now + 86400000L)
    private fun envelope(changes: Map<String, Any?> = emptyMap()) = mapOf<String, Any?>(
        "schemaVersion" to 1, "issuer" to "test-issuer", "purpose" to "CONFIGURATION", "mode" to "CONFIGURE_ONLY",
        "action" to "UPSERT_CONFIGURATION", "tenantId" to scope.tenantId, "deviceId" to scope.deviceId,
        "registrationId" to scope.registrationId, "policyId" to "44444444-4444-4444-8444-444444444444",
        "versionId" to "55555555-5555-4555-8555-555555555555", "deliveryId" to "66666666-6666-4666-8666-666666666666",
        "sourceSequence" to 2, "cursor" to 2, "issuedAt" to now - 1000, "deliveryExpiresAt" to now + 60000,
        "effectiveUntil" to null, "document" to document()) + changes
    private fun sign(body: Map<String, Any?>, signingKey: com.nimbusds.jose.jwk.ECKey = key): String =
        JWSObject(JWSHeader.Builder(JWSAlgorithm.ES256).keyID(key.keyID)
            .type(JOSEObjectType("aimanager-configuration+jws")).build(), Payload(body)).apply {
            sign(ECDSASigner(signingKey))
        }.serialize()

    @Test fun verifiedExplicitFamilyDocumentProducesBoundedRules() {
        val value = verifier.verify(sign(envelope()), scope, now)!!
        assertEquals(3600L, value.rules!!.dailyAllowanceSeconds)
        assertEquals(setOf("com.example.game"), value.rules!!.lockedPackages)
        assertEquals(2L, value.rules!!.policyVersion)
    }
    @Test fun forgedSignatureCannotEnableAssistance() {
        assertNull(verifier.verify(sign(envelope(), ECKeyGenerator(Curve.P_256).generate()), scope, now))
    }
    @Test fun signedDifferentRegistrationCannotEnableAssistance() {
        assertNull(verifier.verify(sign(envelope(mapOf("registrationId" to scope.deviceId))), scope, now))
    }
    @Test fun genericConfigurationCannotEnableAssistance() {
        val plain = document().filterKeys { it != "familyAssistance" }
        assertNull(verifier.verify(sign(envelope(mapOf("document" to plain))), scope, now))
    }
    @Test fun genericReplacementRetainsMonotonicFloorAgainstAnOlderFamilyCache() {
        val plain = document().filterKeys { it != "familyAssistance" }
        val replacement = sign(envelope(mapOf("document" to plain, "sourceSequence" to 3,
            "versionId" to scope.deviceId, "cursor" to 3)))
        assertFalse(verifier.permitsReplacement(replacement, sign(envelope()), scope, now))
        assertTrue(verifier.permitsReplacement(replacement, sign(envelope(mapOf("sourceSequence" to 4,
            "versionId" to scope.registrationId, "cursor" to 4))), scope, now))
    }
    @Test fun explicitSignedDisableDoesNotKeepOldRules() {
        val value = verifier.verify(sign(envelope(mapOf("document" to document(mapOf(
            "schemaVersion" to 1, "mode" to "FAMILY_ASSISTED", "enabled" to false,
            "meteredPackages" to emptyList<String>()))))), scope, now)!!
        assertNull(value.rules)
        assertEquals(2L, value.sourceSequence)
    }
    @Test fun expiredFirstDeliveryIsRejectedWhileSavedSignedRulesCanRestore() {
        val compact = sign(envelope(mapOf("deliveryExpiresAt" to now - 1)))
        assertNull(verifier.verify(compact, scope, now))
        assertNotNull(verifier.verify(compact, scope, now, restoration = true))
    }
    @Test fun exceptionCannotOutliveSignedValidity() {
        val invalid = assistance() + mapOf("exceptionUntil" to now + 86400001L)
        assertNull(verifier.verify(sign(envelope(mapOf("document" to document(invalid)))), scope, now))
    }
    @Test fun reissuedBaseRulesRetainAlreadyExpiredAbsoluteExceptionWithoutExtendingIt() {
        val expiredException = now - 2000L
        val reissued = assistance() + mapOf("exceptionUntil" to expiredException)
        val value = verifier.verify(sign(envelope(mapOf("document" to document(reissued)))), scope, now)
        assertNotNull(value)
        assertEquals(expiredException, value!!.rules!!.exceptionUntilEpochMillis)
        val input = AssistedInput(value.rules!!.copy(dailyAllowanceSeconds = 0), null,
            "com.example.game", now, 1000L, 1, true, true, true)
        val initial = AssistedEvaluator().update(input)
        val evaluated = AssistedEvaluator().update(input.copy(checkpoint = initial.checkpoint,
            wallMillis = now + 1000L, elapsedMillis = 2000L))
        assertEquals(AssistedDecision.RESTRICT, evaluated.decision)
        assertEquals("quota_exhausted", evaluated.reason)
    }
    @Test fun invalidOrUnboundedRulesAreRejected() {
        for (extension in listOf(
            assistance() + mapOf("dailyAllowanceSeconds" to -1),
            assistance() + mapOf("dailyAllowanceSeconds" to 86401),
            assistance() + mapOf("timeZoneId" to "Invented/Zone"),
            assistance() + mapOf("validUntil" to now + 8 * 86400000L),
            assistance() + mapOf("meteredPackages" to emptyList<String>()),
            assistance() + mapOf("meteredPackages" to listOf("invalid")),
            assistance() + mapOf("allowedWindows" to listOf(mapOf("daysOfWeek" to listOf(8), "startMinute" to 0, "endMinute" to 60))),
            assistance() + mapOf("allowedWindows" to listOf(mapOf("daysOfWeek" to listOf(1), "startMinute" to 4294967296L, "endMinute" to 60))),
        )) assertNull(verifier.verify(sign(envelope(mapOf("document" to document(extension)))), scope, now))
    }
    @Test fun onlySuccessfulCurrentRecentNativeInterventionCanReportHomeReturned() {
        val config = verifier.verify(sign(envelope()), scope, now)!!
        val tracker = AssistedInterventionTracker()
        assertEquals("NOT_REQUIRED", tracker.status(config, 1000))
        tracker.record(config, 1000, true)
        assertEquals("HOME_RETURNED", tracker.status(config, 1001))
        assertEquals("NOT_REQUIRED", tracker.status(config, 301001))
        assertEquals("NOT_REQUIRED", tracker.status(config.copy(sourceSequence = 3), 1001))
        assertEquals("NOT_REQUIRED", tracker.status(config.copy(versionId = scope.deviceId), 1001))
        assertEquals("NOT_REQUIRED", tracker.status(config.copy(scope = scope.copy(registrationId = scope.deviceId)), 1001))
        assertEquals("NOT_REQUIRED", tracker.status(config, 999))
        tracker.record(config, 2000, false)
        assertEquals("ACTION_FAILED", tracker.status(config, 2001))
    }
}
