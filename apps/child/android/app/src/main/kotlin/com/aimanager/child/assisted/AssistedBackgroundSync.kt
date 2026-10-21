package com.aimanager.child.assisted

import com.nimbusds.jose.util.JSONObjectUtils
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

interface IdentityPersistence {
    fun read(): String?
    fun write(value: String?)
}
data class IdentityLease(val raw: String?, val epoch: Long) {
    override fun toString() = "IdentityLease(redacted)"
}

/** One process, one encrypted record. Network calls never hold this lock. */
class DurableIdentityGate(private val persistence: IdentityPersistence,
    private val changed: (String?, String?) -> Unit = { _, _ -> }) {
    private val lock = ReentrantLock()
    private var epoch = 0L
    private var confirmed: IdentityLease? = null
    fun lease(): IdentityLease = lock.withLock {
        confirmed = null
        IdentityLease(persistence.read(), epoch).also { confirmed = it }
    }
    fun read(): String? = lease().raw
    fun <T> coordinate(action: () -> T): T = lock.withLock(action)
    fun compareAndSet(expected: String?, value: String?): Boolean = lock.withLock {
        if (persistence.read() != expected) return false
        require(value == null || value.length <= 65536)
        try { persistence.write(value); changed(expected, value) } finally { epoch++; confirmed = null }
        check(persistence.read() == value)
        confirmed = IdentityLease(value, epoch)
        true
    }
    fun replace(lease: IdentityLease, value: String?): Boolean = lock.withLock {
        if (lease.epoch != epoch) return false
        compareAndSet(lease.raw, value)
    }
    fun current(lease: IdentityLease, action: () -> Unit): Boolean = lock.withLock {
        if (lease.epoch != epoch || persistence.read() != lease.raw) return false
        action()
        true
    }
    /** Main-thread service work never waits on migration, encryption or network. */
    fun cached(action: (IdentityLease) -> Unit): Boolean {
        if(!lock.tryLock()) return false
        try {
            val lease = confirmed ?: return false
            if(lease.epoch != epoch) return false
            action(lease)
            return true
        } finally { lock.unlock() }
    }
}

data class BackgroundResponse(val status: Int, val body: Map<String, Any?> = emptyMap()) {
    override fun toString() = "BackgroundResponse($status)"
}
class BackgroundHttpFailure(val status: Int) : Exception("BACKGROUND_HTTP_FAILURE")
fun interface BackgroundTransport {
    fun request(method: String, path: String, credential: String, body: Map<String, Any?>?): BackgroundResponse
}
interface BackgroundRuntime {
    fun clear()
    fun snapshot(): Map<String, Any?>
}
interface BackgroundConfigurations {
    fun synchronize(identity: IdentityLease, scope: AssistedScope, credential: String)
    fun clear()
}

/** Bounded work owned by the already authorized AccessibilityService. */
class AssistedBackgroundSync(
    private val gate: DurableIdentityGate,
    private val transport: BackgroundTransport,
    private val configurations: BackgroundConfigurations,
    private val runtime: BackgroundRuntime,
    private val apiRoot: String,
    private val usage: BackgroundUsage? = null,
    private val nowMillis: () -> Long,
) {
    private var running = false
    @Synchronized fun cycle() {
        if (running) return
        running = true
        try { perform() } catch (_: Exception) {
            // Durable intents survive all uncertain outcomes. No body/token logs.
        } finally { running = false }
    }
    private fun perform() {
        var lease = gate.lease()
        var state = state(lease) ?: run { gate.current(lease) { runtime.clear(); configurations.clear() }; return }
        val phase = state["phase"]
        if (phase == "cleanupPending" || state["authenticationBlocked"] == true) {
            gate.current(lease) { runtime.clear(); configurations.clear() }
            return
        }
        if (phase !in setOf("active", "rotationRequested", "rotationPending", "activationUncertain")) return
        val now = nowMillis()
        // A pending activation may have committed on the server. Its replay is
        // permitted after activateBefore, never after the new token's expiry.
        if (phase == "activationUncertain" || phase == "rotationPending") {
            val pending = pending(state)
            if (phase == "rotationPending" && now >= integer(pending, "activateBefore")) {
                cancel(lease, state); return
            }
            if (now >= integer(pending, "expiresAt")) return
            state["phase"] = "activationUncertain"
            lease = save(lease, state)
            try { request(lease, "POST", "credentials/activate", pending["credential"] as String, emptyMap(), 204,
                    rejectActive = false) }
            catch (failure: BackgroundHttpFailure) {
                if (failure.status == 401 && now < integer(state, "credentialExpiresAt")) cancel(lease, state)
                throw failure
            }
            state["credential"] = pending["credential"]
            state["credentialExpiresAt"] = pending["expiresAt"]
            val expiresAt = integer(pending, "expiresAt")
            state["nativeRotationExpiresAt"] = expiresAt
            state["nativeRotateAfter"] = expiresAt - minOf(86400000L, (expiresAt - now) / 4)
            state.remove("pendingCredential")
            state.remove("authenticationBlocked")
            state["phase"] = "active"
            lease = save(lease, state)
        } else {
            if (now >= integer(state, "credentialExpiresAt")) return
            if (phase == "rotationRequested") { cancel(lease, state); return }
            val expiresAt = integer(state, "credentialExpiresAt")
            val rotateAfter = if (state["nativeRotationExpiresAt"] == state["credentialExpiresAt"] && state["nativeRotateAfter"] is Number)
                integer(state, "nativeRotateAfter").coerceAtMost(expiresAt) else expiresAt - 86400000L
            if (now >= rotateAfter) {
                state["phase"] = "rotationRequested"
                lease = save(lease, state)
                val token = state["credential"] as String
                val result = request(lease, "POST", "credentials/rotate", token, emptyMap(), 200)
                require(uuid(result["credentialId"]) && secret(result["credential"]) && result["credential"] != token)
                val expires = integer(result, "expiresAt")
                val deadline = integer(result, "activateBefore")
                require(expires > now && deadline > now && deadline <= integer(state, "credentialExpiresAt") && deadline <= expires)
                state["pendingCredential"] = result.filterKeys { it in setOf("credentialId", "credential", "expiresAt", "activateBefore") }
                state["phase"] = "rotationPending"
                save(lease, state)
                // Bounded recursion: the persisted phase now chooses activation.
                perform()
                return
            }
        }
        if (state["pendingHeartbeat"] != null || now - (state["lastHeartbeatAt"] as? Number)?.toLong().orZero() >= 60000L) {
            if (state["pendingHeartbeat"] == null) {
                val snapshot = runtime.snapshot()
                state["pendingHeartbeat"] = mapOf("sequence" to integer(state, "heartbeatSequence") + 1,
                    "agentVersion" to "child-native-family/1", "capabilities" to listOf(mapOf(
                        "key" to "usage.report", "reportedSupported" to true,
                        "grantStatus" to if (snapshot["usageGranted"] == true) "GRANTED" else "DENIED")))
            }
            val heartbeat = objectMap(state["pendingHeartbeat"])
            val sequence = integer(heartbeat, "sequence")
            require(sequence == integer(state, "heartbeatSequence") + 1 && sequence <= 9007199254740991L)
            require(heartbeat["agentVersion"] is String && (heartbeat["agentVersion"] as String).length in 1..60)
            require(heartbeat["capabilities"] is List<*> && (heartbeat["capabilities"] as List<*>).size <= 64)
            lease = save(lease, state)
            val result = request(lease, "POST", "heartbeats", state["credential"] as String, heartbeat, 200)
            require(result["registrationId"] == state["registrationId"] && integer(result, "sequence") == sequence &&
                integer(result, "receivedAt") > 0)
            state["heartbeatSequence"] = sequence
            state["lastHeartbeatAt"] = result["receivedAt"]
            state.remove("pendingHeartbeat")
            lease = save(lease, state)
        }
        val scope = AssistedScope(state["tenantId"] as String, state["deviceId"] as String, state["registrationId"] as String)
        val token = state["credential"] as String
        try { usage?.synchronize(lease, scope, token) }
        catch (failure: BackgroundHttpFailure) {
            if(failure.status == 401 || failure.status == 403) { reject(lease); throw failure }
        } catch (_: Exception) { /* Usage consent/query failure does not stall signed arrangements. */ }
        try { configurations.synchronize(lease, scope, token) }
        catch (failure: BackgroundHttpFailure) {
            if (failure.status == 401 || failure.status == 403) reject(lease)
            throw failure
        }
        var snapshot: Map<String, Any?> = emptyMap()
        check(gate.current(lease) { snapshot = runtime.snapshot() })
        if (snapshot["tenantId"] != scope.tenantId || snapshot["deviceId"] != scope.deviceId ||
            snapshot["registrationId"] != scope.registrationId || snapshot["systemEnforced"] != false ||
            !uuid(snapshot["policyId"]) || !uuid(snapshot["versionId"]) ||
            integer(snapshot, "observedAt") !in (now - 300000)..(now + 30000)) return
        request(lease, "POST", "family/assisted-execution-reports", token, snapshot, 200)
    }
    private fun cancel(lease: IdentityLease, state: MutableMap<String, Any?>) {
        request(lease, "POST", "credentials/rotation/cancel", state["credential"] as String, emptyMap(), 204)
        state.remove("pendingCredential")
        state.remove("authenticationBlocked")
        state["phase"] = "active"
        save(lease, state)
    }
    private fun request(lease: IdentityLease, method: String, path: String, token: String,
        body: Map<String, Any?>?, success: Int, rejectActive: Boolean = true): Map<String, Any?> {
        check(gate.current(lease) { })
        val result = transport.request(method, path, token, body)
        if (result.status != success) {
            // 403 can mean FAMILY feature unavailable on an institutional device.
            if (rejectActive && (result.status == 401 || result.status == 403 && !path.startsWith("family/"))) reject(lease)
            throw BackgroundHttpFailure(result.status)
        }
        check(gate.current(lease) { })
        return result.body
    }
    private fun reject(lease: IdentityLease) {
        val state = state(lease) ?: return
        if (state["phase"] == "cleanupPending") return
        state["authenticationBlocked"] = true
        val updated = save(lease, state)
        gate.current(updated) { runtime.clear(); configurations.clear() }
    }
    private fun save(lease: IdentityLease, state: MutableMap<String, Any?>): IdentityLease {
        val now = nowMillis()
        require(now >= integer(state, "observedAt"))
        state["observedAt"] = now
        check(gate.replace(lease, JSONObjectUtils.toJSONString(state)))
        return gate.lease().also { check(it.raw == JSONObjectUtils.toJSONString(state)) }
    }
    private fun state(lease: IdentityLease): MutableMap<String, Any?>? = try {
        val raw = lease.raw ?: return null
        require(raw.length <= 65536)
        val value = JSONObjectUtils.parse(raw)
        require(value["schemaVersion"] == 1L && value["kind"] == "DEVICE_IDENTITY" && value["apiRoot"] == apiRoot &&
            listOf("tenantId", "deviceId", "registrationId").all { uuid(value[it]) } &&
            integer(value, "observedAt") in 1..nowMillis() && integer(value, "heartbeatSequence") >= 0)
        if(value["phase"] != "cleanupPending") require(secret(value["credential"]) && integer(value, "credentialExpiresAt") > 0)
        value
    } catch (_: Exception) { null }
    private fun pending(state: Map<String, Any?>): Map<String, Any?> = objectMap(state["pendingCredential"]).also {
        require(uuid(it["credentialId"]) && secret(it["credential"]) && it["credential"] != state["credential"] &&
            integer(it, "activateBefore") <= integer(state, "credentialExpiresAt") &&
            integer(it, "activateBefore") <= integer(it, "expiresAt"))
    }
    private fun Long?.orZero() = this ?: 0L
}

internal fun integer(map: Map<*, *>, name: String): Long {
    val value = map[name] as Number
    val long = value.toLong()
    require(long in 0..9007199254740991L && value.toDouble() == long.toDouble())
    return long
}
internal fun uuid(value: Any?) = value is String && Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").matches(value)
internal fun secret(value: Any?) = value is String && Regex("^[A-Za-z0-9_-]{43}$").matches(value)
@Suppress("UNCHECKED_CAST") internal fun objectMap(value: Any?) = (value as Map<String, Any?>).toMutableMap()
