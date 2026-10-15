package com.aimanager.child

import org.junit.Assert.*
import org.junit.Test

class ManagedBindingClaimsTest {
    private val now = 1792080000000L
    private fun args(): MutableMap<String, Any> = mutableMapOf(
        "challengeId" to "77777777-7777-4777-8777-777777777777",
        "nonce" to "A".repeat(43),
        "audience" to "ai-manager:managed-agent-binding",
        "createdAt" to now - 1000,
        "expiresAt" to now + 598999,
        "nowMillis" to now
    )
    @Test fun createsOnlySixClaimsAndRoundsExpiryDown() {
        val claims = ManagedBindingClaims.create(args())
        assertEquals(setOf("sub", "nonce", "aud", "iat", "exp", "jti"), claims.keys)
        assertEquals(now / 1000, claims["iat"])
        assertEquals((now + 598999) / 1000, claims["exp"])
        assertEquals(listOf("ai-manager:managed-agent-binding"), claims["aud"])
        assertNotEquals(ManagedBindingClaims.create(args())["jti"], claims["jti"])
    }
    @Test fun rejectsInvalidChallenges() {
        val changes = listOf(
            "challengeId" to "77777777-7777-1777-8777-777777777777",
            "nonce" to "A".repeat(42) + "B",
            "audience" to "ai-manager:cleanup",
            "createdAt" to now + 30001,
            "createdAt" to -1L,
            "expiresAt" to now,
            "expiresAt" to now + 600000,
            "nowMillis" to now.toDouble(),
            "nowMillis" to 9007199254740992L
        )
        changes.forEach { (key, value) ->
            try { ManagedBindingClaims.create(args().apply { put(key, value) }); fail(key) }
            catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun boundedClockSkewCannotIncreaseProofLifetime() {
        val claims = ManagedBindingClaims.create(args().apply {
            put("createdAt", now + 30000); put("expiresAt", now + 630000)
        })
        assertEquals(600L, (claims["exp"] as Long) - (claims["iat"] as Long))
    }
}
