package com.aimanager.child

import com.nimbusds.jose.JWSObject
import com.nimbusds.jose.util.Base64URL

/** Validate the app-internal transport envelope before invoking AndroidX. Server verifies identity. */
internal object ManagedFeedbackProof {
    private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    fun expiresAt(compact: String, now: Long): Long {
        require(compact.length in 1..1000)
        val parts = compact.split('.')
        require(parts.size == 3 && parts.all { Regex("^[A-Za-z0-9_-]+$").matches(it) && Base64URL.encode(Base64URL(it).decode()).toString() == it })
        val proof = JWSObject.parse(compact)
        val header = proof.header.toJSONObject()
        require(header.size == 2 && header["alg"] == "ES256" && header["typ"] == "JWT")
        require(proof.signature.decode().size == 64)
        val claims = proof.payload.toJSONObject()
        require(claims.keys == setOf("sub", "nonce", "aud", "iat", "exp", "jti"))
        require(claims["sub"] is String && uuid.matches(claims["sub"] as String))
        require(claims["jti"] is String && uuid.matches(claims["jti"] as String))
        require(claims["aud"] == listOf("ai-manager:managed-agent-binding"))
        val nonce = claims["nonce"] as? String
        require(nonce != null && Regex("^[A-Za-z0-9_-]{43}$").matches(nonce) && Base64URL.encode(Base64URL(nonce).decode()).toString() == nonce)
        fun seconds(name: String): Long {
            val value = claims[name]
            require(value is Long || value is Int)
            return (value as Number).toLong().also { require(it in 0..9007199254740L) }
        }
        val issued = seconds("iat") * 1000
        val expires = seconds("exp") * 1000
        require(now > 0 && issued <= now + 30000 && expires > now && expires > issued && expires - issued <= 600000)
        return expires
    }
}
