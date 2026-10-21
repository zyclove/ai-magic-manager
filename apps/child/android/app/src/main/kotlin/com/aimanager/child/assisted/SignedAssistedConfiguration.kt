package com.aimanager.child.assisted

import com.nimbusds.jose.JOSEObjectType
import com.nimbusds.jose.JWSAlgorithm
import com.nimbusds.jose.JWSObject
import com.nimbusds.jose.crypto.ECDSAVerifier
import com.nimbusds.jose.jwk.Curve
import com.nimbusds.jose.jwk.ECKey
import com.nimbusds.jose.jwk.JWKSet
import java.util.TimeZone

data class AssistedScope(val tenantId: String, val deviceId: String, val registrationId: String)
data class SignedAssistedConfiguration(
    val compact: String, val scope: AssistedScope, val versionId: String,
    val rules: AssistedRules?, val sourceSequence: Long, val policyId: String,
)

class AssistedInterventionTracker {
    private var configuration: SignedAssistedConfiguration? = null
    private var observedElapsed = 0L
    private var succeeded = false
    fun record(configuration: SignedAssistedConfiguration, elapsedMillis: Long, succeeded: Boolean) {
        this.configuration = configuration
        this.observedElapsed = elapsedMillis
        this.succeeded = succeeded
    }
    fun status(configuration: SignedAssistedConfiguration?, elapsedMillis: Long): String {
        val observed = this.configuration ?: return "NOT_REQUIRED"
        if (configuration == null || observed.scope != configuration.scope ||
            observed.policyId != configuration.policyId || observed.versionId != configuration.versionId ||
            observed.sourceSequence != configuration.sourceSequence ||
            elapsedMillis - observedElapsed !in 0..300000L) return "NOT_REQUIRED"
        return if (succeeded) "HOME_RETURNED" else "ACTION_FAILED"
    }
}

/** Native trust boundary: only an installation-pinned ES256 document is accepted. */
class AssistedConfigurationVerifier(private val issuer: String, private val publicJwks: String) {
    fun permitsReplacement(previous: String?, next: String, scope: AssistedScope, now: Long): Boolean {
        val old = previous?.let { verifyEnvelope(it, scope, now, true) } ?: return true
        val value = verifyEnvelope(next, scope, now, true) ?: return false
        if(old["policyId"] != value["policyId"]) return false
        val before = number(old, "sourceSequence")
        val after = number(value, "sourceSequence")
        return if(after != before) after > before && old["versionId"] != value["versionId"] else
            old["versionId"] == value["versionId"] && old["action"] == value["action"] &&
                old["document"] == value["document"] && old["cursor"] == value["cursor"]
    }
    /** Generic CONFIGURE_ONLY receipt verification does not grant family authority. */
    fun verifyEnvelope(compact: String, scope: AssistedScope, nowMillis: Long,
        restoration: Boolean = false): Map<String, Any?>? = try {
        require(issuer.isNotBlank() && publicJwks.isNotBlank() && compact.length <= 1048576)
        require(listOf(scope.tenantId, scope.deviceId, scope.registrationId).all { uuid.matches(it) })
        val keys = JWKSet.parse(publicJwks).keys
        require(keys.isNotEmpty() && keys.size <= 32 && keys.all { it is ECKey && !it.isPrivate })
        val jws = JWSObject.parse(compact)
        require(jws.header.algorithm == JWSAlgorithm.ES256 &&
            jws.header.type == JOSEObjectType("aimanager-configuration+jws") &&
            jws.header.toJSONObject().keys.all { it in setOf("alg", "typ", "kid") })
        val key = keys.single { it.keyID == jws.header.keyID } as ECKey
        require(key.curve == Curve.P_256 && jws.verify(ECDSAVerifier(key)))
        val body = jws.payload.toJSONObject()
        require(body["issuer"] == issuer && body["tenantId"] == scope.tenantId &&
            body["deviceId"] == scope.deviceId && body["registrationId"] == scope.registrationId &&
            number(body, "schemaVersion") == 1L && body["purpose"] == "CONFIGURATION" &&
            body["mode"] == "CONFIGURE_ONLY" && body["effectiveUntil"] == null)
        listOf("policyId", "versionId", "deliveryId").forEach { id(body, it) }
        require(number(body, "sourceSequence") >= 1 && number(body, "cursor") >= 1)
        val issued = number(body, "issuedAt")
        val expires = number(body, "deliveryExpiresAt")
        require(expires > issued && expires - issued <= 86400000L &&
            (restoration || issued <= nowMillis && nowMillis < expires))
        when(body["action"]) {
            "REMOVE_CONFIGURATION" -> require(body["document"] == null)
            "UPSERT_CONFIGURATION" -> {
                val doc = body["document"] as Map<*, *>
                require(doc["name"] is String && listOf("rules", "applications", "schedules", "protectedPackageExemptions")
                    .all { doc[it] is List<*> })
                require((doc["rules"] as List<*>).all { it is Map<*, *> && it["effectiveEffect"] == null })
            }
            else -> error("UNSUPPORTED_CONFIGURATION")
        }
        body
    } catch (_: Exception) { null }

    fun verify(compact: String, scope: AssistedScope, nowMillis: Long,
        restoration: Boolean = false): SignedAssistedConfiguration? = try {
        require(issuer.isNotBlank() && publicJwks.isNotBlank() && compact.length <= 1048576)
        require(listOf(scope.tenantId, scope.deviceId, scope.registrationId).all { uuid.matches(it) })
        val keys = JWKSet.parse(publicJwks).keys
        require(keys.isNotEmpty() && keys.size <= 32 && keys.all { it is ECKey && !it.isPrivate })
        val jws = JWSObject.parse(compact)
        val header = jws.header
        require(header.algorithm == JWSAlgorithm.ES256 &&
            header.type == JOSEObjectType("aimanager-configuration+jws") &&
            header.toJSONObject().keys.all { it in setOf("alg", "typ", "kid") })
        val key = keys.single { it.keyID == header.keyID } as ECKey
        require(key.curve == Curve.P_256 && jws.verify(ECDSAVerifier(key)))
        val body = jws.payload.toJSONObject()
        require(body["issuer"] == issuer && body["tenantId"] == scope.tenantId &&
            body["deviceId"] == scope.deviceId && body["registrationId"] == scope.registrationId)
        require(number(body, "schemaVersion") == 1L && body["purpose"] == "CONFIGURATION" &&
            body["mode"] == "CONFIGURE_ONLY" && body["effectiveUntil"] == null)
        val policy = id(body, "policyId")
        val version = id(body, "versionId")
        id(body, "deliveryId")
        val sequence = number(body, "sourceSequence").also { require(it >= 1) }
        require(number(body, "cursor") >= 1)
        val issued = number(body, "issuedAt")
        val expires = number(body, "deliveryExpiresAt")
        require(issued >= 0 && expires > issued && expires - issued <= 86400000L)
        require(restoration || (issued <= nowMillis && nowMillis < expires))
        if (body["action"] == "REMOVE_CONFIGURATION") {
            require(body["document"] == null)
            SignedAssistedConfiguration(compact, scope, version, null, sequence, policy)
        } else {
            require(body["action"] == "UPSERT_CONFIGURATION")
            val doc = body["document"] as Map<*, *>
            require(doc["name"] is String && listOf("rules", "applications", "schedules", "protectedPackageExemptions")
                .all { doc[it] is List<*> })
            require((doc["rules"] as List<*>).all { it is Map<*, *> && it["effectiveEffect"] == null })
            val assisted = doc["familyAssistance"] as Map<*, *>
            require(number(assisted, "schemaVersion") == 1L && assisted["mode"] == "FAMILY_ASSISTED")
            require(assisted["enabled"] is Boolean)
            val rules = if (assisted["enabled"] == false) null else {
                val seconds = number(assisted, "dailyAllowanceSeconds").also { require(it in 0..86400) }
                val zone = assisted["timeZoneId"] as String
                require(zone in timezones)
                val until = number(assisted, "validUntil")
                require(until > issued && until - issued <= 7 * 86400000L)
                val exception = assisted["exceptionUntil"]?.let { number(assisted, "exceptionUntil") }
                require(exception == null || exception in 0..until)
                val packages = (assisted["meteredPackages"] as List<*>).map { it as String }
                require(packages.isNotEmpty() && packages.size <= 100 && packages.distinct().size == packages.size &&
                    packages.all { it.length <= 255 && packageName.matches(it) })
                val windows = (assisted["allowedWindows"] as List<*>).map { raw ->
                    val window = raw as Map<*, *>
                    val days = (window["daysOfWeek"] as List<*>).map { day ->
                        require(day is Number && day.toDouble() == day.toInt().toDouble()); day.toInt()
                    }
                    val start = number(window, "startMinute").also { require(it in 0..1439L) }.toInt()
                    val end = number(window, "endMinute").also { require(it in 0..1440L) }.toInt()
                    require(days.isNotEmpty() && days.size <= 7 && days.distinct().size == days.size &&
                        days.all { it in 1..7 } && start in 0..1439 && end in 0..1440 && start != end)
                    AssistedSchedule(days.toSet(), start, end)
                }
                require(windows.size <= 32)
                AssistedRules(policy, sequence, seconds, zone, packages.toSet(), windows, until, exception)
            }
            SignedAssistedConfiguration(compact, scope, version, rules, sequence, policy)
        }
    } catch (_: Exception) { null }

    private fun number(body: Map<*, *>, name: String): Long {
        val value = body[name] as Number
        val long = value.toLong()
        require(long in 0..9007199254740991L && value.toDouble() == long.toDouble())
        return long
    }
    private fun id(body: Map<*, *>, name: String) = (body[name] as String).also { require(uuid.matches(it)) }
    companion object {
        private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        private val packageName = Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")
        private val timezones = TimeZone.getAvailableIDs().toSet()
    }
}
