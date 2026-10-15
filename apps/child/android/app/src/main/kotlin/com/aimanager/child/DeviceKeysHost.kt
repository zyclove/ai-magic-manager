package com.aimanager.child

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.nimbusds.jose.JOSEObjectType
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSHeader
import com.nimbusds.jose.JWSObject
import com.nimbusds.jose.Payload
import com.nimbusds.jose.crypto.ECDSASigner
import com.nimbusds.jose.crypto.ECDSAVerifier
import com.nimbusds.jose.jwk.Curve
import com.nimbusds.jose.jwk.ECKey
import com.nimbusds.jose.jwk.KeyUse
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.util.UUID
import org.json.JSONObject

/** AndroidKeyStore signing boundary. The private key never crosses the channel.
 * A keystore alias does not by itself prove hardware backing or attestation. */
internal class DeviceKeysHost {
    private val aliasPattern = Regex("^aimanager\\.device\\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private val uuidPattern = Regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    private val store: KeyStore get() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    fun invoke(method: String, arguments: Any?): Any {
        val args = arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        return when (method) {
            "generate" -> generate()
            "proof" -> proof(args)
            "cleanupProof" -> cleanupProof(args)
            "managedBindingProof" -> managedBindingProof(args)
            "delete" -> delete(args)
            else -> throw IllegalArgumentException("Unsupported key operation")
        }
    }

    private fun generate(): String {
        val alias = "aimanager.device.${UUID.randomUUID()}"
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore")
        generator.initialize(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .build())
        generator.generateKeyPair()
        return alias
    }

    private fun string(args: Map<*, *>, name: String, maximum: Int = 4096): String {
        val value = args[name] as? String
        require(value != null && value.isNotEmpty() && value.length <= maximum)
        return value
    }

    private fun uuid(args: Map<*, *>, name: String): String {
        val value = string(args, name, 36)
        require(uuidPattern.matches(value))
        return value
    }

    private fun alias(args: Map<*, *>): String {
        val value = string(args, "handle", 54)
        require(aliasPattern.matches(value))
        return value
    }

    private fun issued(args: Map<*, *>): Long {
        val now = (args["nowMillis"] as? Number)?.toLong() ?: throw IllegalArgumentException()
        require(now > 0 && now <= 9007199254740991L)
        return now / 1000
    }

    private fun privateKey(handle: String): PrivateKey =
        (store.getKey(handle, null) as? PrivateKey) ?: throw IllegalStateException("Key unavailable")

    private fun publicKey(handle: String): ECKey {
        val public = store.getCertificate(handle)?.publicKey as? ECPublicKey
            ?: throw IllegalStateException("Public key unavailable")
        return ECKey.Builder(Curve.P_256, public)
            .algorithm(JWSAlgorithm.ES256)
            .keyUse(KeyUse.SIGNATURE)
            .build()
    }

    private fun sign(handle: String, header: JWSHeader, body: JSONObject): String {
        val objectToSign = JWSObject(header, Payload(body.toString()))
        objectToSign.sign(ECDSASigner(privateKey(handle), Curve.P_256))
        // Refuse a malformed or mismatched JOSE signature before it leaves
        // this process; the server independently verifies registration scope.
        check(objectToSign.verify(ECDSAVerifier(publicKey(handle))))
        return objectToSign.serialize()
    }

    private fun proof(args: Map<*, *>): Map<String, String> {
        val handle = alias(args)
        val enrollmentId = uuid(args, "enrollmentId")
        val token = string(args, "token")
        val purpose = string(args, "purpose", 40)
        require(purpose == "ai-manager:enrollment-claim" || purpose == "ai-manager:enrollment-recover")
        val issuedAt = issued(args)
        val payload = JSONObject()
            .put("sub", enrollmentId)
            .put("aud", org.json.JSONArray().put(purpose))
            .put("nonce", token)
            .put("iat", issuedAt)
            .put("exp", issuedAt + 60)
            .put("jti", UUID.randomUUID().toString())
        val header = JWSHeader.Builder(JWSAlgorithm.ES256)
            .type(JOSEObjectType.JWT)
            .build()
        val key = publicKey(handle)
        return mapOf("publicKeyJwk" to key.toJSONString(), "compact" to sign(handle, header, payload))
    }

    private fun cleanupProof(args: Map<*, *>): Map<String, String> {
        val handle = alias(args)
        val tenantId = uuid(args, "tenantId")
        val deviceId = uuid(args, "deviceId")
        val registrationId = uuid(args, "registrationId")
        val action = string(args, "action", 7)
        require(action == "READ" || action == "RECEIPT")
        val operationId = args["operationId"]?.let {
            require(it is String && uuidPattern.matches(it))
            it
        }
        require(action != "RECEIPT" || operationId != null)
        val issuedAt = issued(args)
        val payload = JSONObject()
            .put("iss", "device:$registrationId")
            .put("sub", deviceId)
            .put("aud", org.json.JSONArray().put("ai-manager:cleanup"))
            .put("purpose", "AGENT_CLEANUP")
            .put("tenantId", tenantId)
            .put("registrationId", registrationId)
            .put("action", action)
            .put("iat", issuedAt)
            .put("exp", issuedAt + 60)
            .put("jti", UUID.randomUUID().toString())
        if (operationId != null) payload.put("operationId", operationId)
        val header = JWSHeader.Builder(JWSAlgorithm.ES256)
            .type(JOSEObjectType("aimanager-cleanup-auth+jwt"))
            .keyID(registrationId)
            .build()
        return mapOf("compact" to sign(handle, header, payload),
            "keyThumbprint" to publicKey(handle).computeThumbprint().toString())
    }

    private fun managedBindingProof(args: Map<*, *>): Map<String, String> {
        val handle = alias(args)
        val claims = ManagedBindingClaims.create(args)
        val header = JWSHeader.Builder(JWSAlgorithm.ES256).type(JOSEObjectType.JWT).build()
        val compact = sign(handle, header, JSONObject(claims))
        check(compact.length <= 1000)
        return mapOf("compact" to compact)
    }

    private fun delete(args: Map<*, *>): Boolean {
        val handle = alias(args)
        val keyStore = store
        if (keyStore.containsAlias(handle)) keyStore.deleteEntry(handle)
        return !store.containsAlias(handle)
    }
}
