package com.aimanager.child

import com.nimbusds.jose.util.Base64URL
import java.util.UUID

/** Minimal feedback payload; no caller-provided claims, identifiers or key headers. */
internal object ManagedBindingClaims {
    private const val audience = "ai-manager:managed-agent-binding"
    private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
    private fun integer(args: Map<*, *>, key: String): Long {
        val value = args[key]
        require(value is Long || value is Int)
        val result = (value as Number).toLong()
        require(result in 0..9007199254740991L)
        return result
    }
    fun create(args: Map<*, *>): Map<String, Any> {
        val id = args["challengeId"] as? String
        val nonce = args["nonce"] as? String
        require(id != null && uuid.matches(id))
        require(args["audience"] == audience)
        require(nonce != null && Regex("^[A-Za-z0-9_-]{43}$").matches(nonce))
        require(Base64URL.encode(Base64URL(nonce).decode()).toString() == nonce)
        val created = integer(args, "createdAt")
        val expires = integer(args, "expiresAt")
        val now = integer(args, "nowMillis")
        require(expires > created && expires - created <= 600000)
        require(now > 0 && now >= created - 30000 && now < (expires / 1000) * 1000)
        val issued = now / 1000
        return mapOf("sub" to id, "nonce" to nonce, "aud" to listOf(audience),
            "iat" to issued, "exp" to minOf(expires / 1000, issued + 600),
            "jti" to UUID.randomUUID().toString())
    }
}
