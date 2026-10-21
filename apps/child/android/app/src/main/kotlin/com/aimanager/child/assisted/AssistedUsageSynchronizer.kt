package com.aimanager.child.assisted

import com.nimbusds.jose.util.JSONObjectUtils
import java.util.UUID
import java.util.TimeZone

interface BackgroundUsage {
    fun synchronize(identity: IdentityLease, scope: AssistedScope, credential: String)
}
interface UsageJournalStore {
    fun read(): String?
    fun compareAndSet(expected: String?, replacement: String?): Boolean
}
data class NativeUsageFacts(val granted: Boolean, val unlocked: Boolean, val supported: Boolean, val profile: String)
interface NativeUsageSource {
    fun inspect(): NativeUsageFacts
    fun sample(): Map<String, Any?>
}
class AssistedUsageSynchronizer(private val gate: DurableIdentityGate, private val store: UsageJournalStore,
    private val source: NativeUsageSource, private val transport: BackgroundTransport,
    private val nowMillis: () -> Long) : BackgroundUsage {
    @Synchronized override fun synchronize(identity: IdentityLease, scope: AssistedScope, credential: String) {
        var expected: String? = null
        check(gate.current(identity) { expected = store.read() })
        val journal = expected?.let {
            require(it.toByteArray(Charsets.UTF_8).size <= 1048576)
            JSONObjectUtils.parse(it)
        } ?: empty(scope)
        require(journal["scope"] == scopeKey(scope) && integer(journal, "schema") in 1..2)
        listOf("inventorySequence", "usageSequence", "inventoryCount", "usageCount").forEach { integer(journal, it) }
        fun save() {
            val raw = JSONObjectUtils.toJSONString(journal)
            require(raw.toByteArray(Charsets.UTF_8).size <= 1048576)
            check(gate.current(identity) { check(store.compareAndSet(expected, raw)); expected = raw })
        }
        fun clearUsage() { journal["pendingUsage"] = null; journal["usageCount"] = 0L; journal["lastUsageAt"] = null }
        fun forgetReports() {
            clearUsage()
            listOf("pendingInventory", "pendingInventoryAt", "lastInventoryAt", "pendingPermission", "lastPermissionAt", "lastPermissionPackage")
                .filter { journal.containsKey(it) }.forEach { journal[it] = null }
            journal["inventoryCount"] = 0L
        }
        fun request(method: String, path: String, body: Map<String, Any?>? = null): BackgroundResponse {
            check(gate.current(identity) { check(store.read() == expected) })
            return transport.request(method, path, credential, body)
        }
        val facts = source.inspect()
        if(!facts.granted || !facts.unlocked || !facts.supported) { clearUsage(); save() }
        val settings = request("GET", "observation-settings")
        if(settings.status != 200) {
            if(settings.status == 403 && settings.body["errorCode"] == "OBSERVATION_NOT_AUTHORIZED") {
                forgetReports(); journal["authorization"] = null; save(); return
            }
            throw BackgroundHttpFailure(settings.status)
        }
        val authorization = settings.body
        require(authorization.keys == setOf("deviceId", "registrationId", "version", "inventoryEnabled", "usageEnabled", "updatedAt") &&
            authorization["deviceId"] == scope.deviceId && authorization["registrationId"] == scope.registrationId &&
            authorization["inventoryEnabled"] is Boolean && authorization["usageEnabled"] is Boolean)
        val version = integer(authorization, "version")
        require(if(version == 0L) authorization["updatedAt"] == null && authorization["usageEnabled"] == false &&
            authorization["inventoryEnabled"] == false else integer(authorization, "updatedAt") > 0)
        val previousVersion = (journal["authorization"] as? Map<*, *>)?.let { integer(it, "version") } ?: 0L
        require(version >= previousVersion)
        if(version != previousVersion) forgetReports()
        journal["authorization"] = authorization
        if(authorization["inventoryEnabled"] != true) {
            listOf("pendingInventory", "pendingInventoryAt", "lastInventoryAt", "pendingPermission", "lastPermissionAt", "lastPermissionPackage")
                .filter { journal.containsKey(it) }.forEach { journal[it] = null }
            journal["inventoryCount"] = 0L
        }
        if(authorization["usageEnabled"] != true) clearUsage()
        // Consent is durable before the first sensitive platform query.
        save()
        if(authorization["usageEnabled"] != true || !facts.granted || !facts.unlocked || !facts.supported) return
        val now = nowMillis()
        var pending = (journal["pendingUsage"] as? Map<*, *>)?.let { objectMap(it) }
        if(pending != null && integer(pending, "observedAt") < now - 7 * 86400000L) {
            clearUsage(); save(); pending = null
        }
        if(pending == null) {
            val last = journal["lastUsageAt"] as? Number
            if(last != null && now - last.toLong() < 15 * 60000L) return
            val sample = source.sample()
            require(sample["profile"] == facts.profile)
            val sequence = integer(journal, "usageSequence") + 1L
            require(sequence <= 9007199254740991L)
            pending = (sample + mapOf("reportId" to UUID.randomUUID().toString(), "sequence" to sequence,
                "authorizationVersion" to version, "source" to "ANDROID_USAGE_STATS")).toMutableMap()
            validate(pending, now)
            journal["usageSequence"] = sequence
            journal["pendingUsage"] = pending
            save()
        }
        val payload = pending
        validate(payload, now)
        require(integer(payload, "sequence") == integer(journal, "usageSequence") &&
            integer(payload, "authorizationVersion") == version && payload["profile"] == facts.profile)
        val current = source.inspect()
        if(!current.granted || !current.unlocked || !current.supported || current.profile != facts.profile) {
            clearUsage(); save(); return
        }
        val response = request("POST", "usage-observations", payload)
        if(response.status != 200) {
            val code = response.body["errorCode"]
            if(response.status == 403 && code == "OBSERVATION_NOT_AUTHORIZED" ||
                response.status == 409 && code == "OBSERVATION_AUTHORIZATION_CHANGED") {
                forgetReports(); journal["authorization"] = null; save(); return
            }
            if(response.status == 400) { clearUsage(); save() }
            throw BackgroundHttpFailure(response.status)
        }
        val ack = response.body
        require(ack.keys == setOf("registrationId", "sequence", "reportId", "receivedAt") &&
            ack["registrationId"] == scope.registrationId && ack["reportId"] == payload["reportId"] &&
            integer(ack, "sequence") == integer(payload, "sequence") && integer(ack, "receivedAt") > 0)
        journal["lastUsageAt"] = ack["receivedAt"]
        journal["usageCount"] = (payload["applications"] as List<*>).size.toLong()
        journal["pendingUsage"] = null
        save()
    }
    private fun empty(scope: AssistedScope) = mutableMapOf<String, Any?>("schema" to 2L, "scope" to scopeKey(scope),
        "authorization" to null, "permissionAuthorization" to null, "inventorySequence" to 0L, "usageSequence" to 0L,
        "permissionSequence" to 0L, "pendingPermission" to null, "lastPermissionAt" to null,
        "lastPermissionPackage" to null, "pendingInventory" to null, "pendingInventoryAt" to null,
        "pendingUsage" to null, "lastInventoryAt" to null, "lastUsageAt" to null, "inventoryCount" to 0L, "usageCount" to 0L)
    private fun scopeKey(scope: AssistedScope) = "${scope.tenantId}.${scope.deviceId}.${scope.registrationId}"
    private fun validate(body: Map<String, Any?>, now: Long) {
        require(body.keys == setOf("reportId", "sequence", "authorizationVersion", "source", "profile", "queryStart", "queryEnd",
            "observedAt", "timeZone", "applications") && uuid(body["reportId"]) && integer(body, "sequence") > 0 &&
            integer(body, "authorizationVersion") > 0 && body["source"] == "ANDROID_USAGE_STATS" &&
            body["profile"] in setOf("PRIMARY", "WORK", "SECONDARY", "UNKNOWN") && body["timeZone"] in TimeZone.getAvailableIDs())
        val observed = integer(body, "observedAt")
        val start = integer(body, "queryStart")
        val end = integer(body, "queryEnd")
        require(start > 0 && start < end && end <= observed && end - start <= 2 * 86400000L && observed in (now - 7 * 86400000L)..(now + 300000))
        val applications = body["applications"] as List<*>
        require(applications.size <= 500)
        val seen = mutableSetOf<String>()
        for(raw in applications) {
            val app = objectMap(raw)
            val name = app["packageName"] as String
            val label = app["displayName"] as String
            val first = integer(app, "firstTimeStamp")
            val last = integer(app, "lastTimeStamp")
            val duration = integer(app, "foregroundMillis")
            require(app.keys == setOf("packageName", "displayName", "firstTimeStamp", "lastTimeStamp", "foregroundMillis") &&
                name.length <= 255 && name.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")) &&
                label.isNotBlank() && label.length <= 100 && label.none { it.isISOControl() } &&
                first > 0 && first <= last && first >= observed - 7 * 86400000L && last <= observed + 300000L &&
                duration <= last - first && duration <= 7 * 86400000L && seen.add("$name|$first|$last"))
        }
    }
}
