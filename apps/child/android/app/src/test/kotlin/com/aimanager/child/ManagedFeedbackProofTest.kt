package com.aimanager.child

import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JOSEObjectType
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.JWSObject
import com.nimbusds.jose.Payload
import com.nimbusds.jose.crypto.ECDSASigner
import com.nimbusds.jose.jwk.Curve
import com.nimbusds.jose.jwk.gen.ECKeyGenerator
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class ManagedFeedbackProofTest {
    private val now = 1792080000000L
    private fun proof(extra: Map<String, Any> = emptyMap(), kid: Boolean = false): String {
        val claims = mutableMapOf<String, Any>("sub" to UUID.randomUUID().toString(), "nonce" to "A".repeat(43),
            "aud" to listOf("ai-manager:managed-agent-binding"), "iat" to now / 1000,
            "exp" to now / 1000 + 599, "jti" to UUID.randomUUID().toString())
        claims.putAll(extra)
        val header = JWSHeader.Builder(JWSAlgorithm.ES256).type(JOSEObjectType.JWT)
        if (kid) header.keyID("not-permitted")
        val signed = JWSObject(header.build(), Payload(claims))
        signed.sign(ECDSASigner(ECKeyGenerator(Curve.P_256).generate()))
        return signed.serialize()
    }
    @Test fun acceptsOnlyTheFixedShortLivedEnvelope() {
        assertEquals(now + 599000, ManagedFeedbackProof.expiresAt(proof(), now))
    }
    @Test fun rejectsIdentityFieldsWrongPurposeAndInvalidTimes() {
        listOf(mapOf("email" to "private@example.invalid"), mapOf("aud" to listOf("other")),
            mapOf("exp" to now / 1000), mapOf("iat" to now / 1000 + 31),
            mapOf("exp" to now / 1000 + 601), mapOf("iat" to 1.5),
            mapOf("nonce" to "B".repeat(43))).forEach { extra ->
            try { ManagedFeedbackProof.expiresAt(proof(extra), now); fail("accepted invalid feedback") }
            catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun rejectsExtraHeaderAndOversizedFeedback() {
        for (value in listOf(proof(kid = true), "x".repeat(1001))) {
            try { ManagedFeedbackProof.expiresAt(value, now); fail("accepted invalid feedback") }
            catch (_: IllegalArgumentException) { }
        }
    }
}
