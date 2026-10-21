package com.aimanager.child.assisted

import com.nimbusds.jose.util.JSONObjectUtils
import java.security.MessageDigest
import java.util.UUID

interface BackgroundJournalPersistence {
    fun read(): String?
    fun write(value: String?)
}

class AssistedConfigurationJournal(
    private val gate: DurableIdentityGate,
    private val persistence: BackgroundJournalPersistence,
    private val transport: BackgroundTransport,
    private val verifier: AssistedConfigurationVerifier,
    private val apply: (AssistedScope, List<String>) -> Unit,
    private val nowMillis: () -> Long,
) : BackgroundConfigurations {
    private var expectedRaw: String? = null
    @Synchronized override fun clear() { persistence.write(null); expectedRaw = null }
    @Synchronized override fun synchronize(identity: IdentityLease, scope: AssistedScope, credential: String) {
        var journal = restore(scope)
        if (journal["policies"] != emptyMap<String, Any?>()) {
            check(gate.current(identity) { check(persistence.read() == expectedRaw); apply(scope, compacts(journal)) })
        }
        flush(identity, journal, scope, credential)
        repeat(3) {
            val after = integer(journal, "cursor")
            check(gate.current(identity) { })
            val response = transport.request("GET", "configurations?after=$after&limit=10", credential, null)
            if(response.status != 200) throw BackgroundHttpFailure(response.status)
            val page = response.body
            val next = integer(page, "nextAfter")
            val serverTime = integer(page, "serverTime")
            val rawItems = page["items"] as List<*>
            require(next >= after && page["hasMore"] is Boolean && rawItems.size <= 10)
            val staged = JSONObjectUtils.parse(JSONObjectUtils.toJSONString(journal))
            val policies = objectMap(staged["policies"])
            val receipts = (staged["receipts"] as List<*>).map { objectMap(it) }.toMutableList()
            var previousCursor = after
            val pagePolicies = mutableSetOf<String>()
            for(raw in rawItems) {
                val item = objectMap(raw)
                val compact = item["compactJws"] as String
                val envelope = verifier.verifyEnvelope(compact, scope, nowMillis(), true)
                    ?: error("CONFIGURATION_SIGNATURE_INVALID")
                val policy = envelope["policyId"] as String
                val cursor = integer(envelope, "cursor")
                require(item["id"] == envelope["deliveryId"] && integer(item, "cursor") == cursor &&
                    integer(item, "deliveryExpiresAt") == integer(envelope, "deliveryExpiresAt") &&
                    integer(envelope, "issuedAt") <= serverTime && cursor > previousCursor && cursor <= next &&
                    pagePolicies.add(policy) && item["state"] in setOf("SERVED", "DEVICE_REPORTED_RECEIVED", "DEVICE_REPORTED_STORED"))
                previousCursor = cursor
                val previousCompact = policies[policy] as? String
                if(previousCompact != compact) {
                    require(integer(envelope, "issuedAt") <= nowMillis() && nowMillis() < integer(envelope, "deliveryExpiresAt"))
                    if(previousCompact != null) {
                        val previous = verifier.verifyEnvelope(previousCompact, scope, nowMillis(), true)!!
                        val sequence = integer(envelope, "sourceSequence")
                        val previousSequence = integer(previous, "sourceSequence")
                        require(sequence >= previousSequence && envelope["deliveryId"] != previous["deliveryId"])
                        require(if(sequence == previousSequence) envelope["versionId"] == previous["versionId"] &&
                            envelope["action"] == previous["action"] && envelope["document"] == previous["document"] &&
                            cursor == integer(previous, "cursor") else envelope["versionId"] != previous["versionId"])
                    }
                }
                val doc = envelope["document"] as? Map<*, *>
                if(doc?.containsKey("familyAssistance") == true) {
                    require(verifier.verify(compact, scope, nowMillis(), true) != null)
                }
                policies[policy] = compact
                if(receipts.none { it["deliveryId"] == envelope["deliveryId"] && it["envelopeHash"] == hash(compact) }) {
                    receipts.add(mapOf("receiptId" to UUID.randomUUID().toString(), "deliveryId" to envelope["deliveryId"],
                        "cursor" to cursor, "envelopeHash" to hash(compact), "stage" to "STORED", "compact" to compact).toMutableMap())
                }
            }
            require(page["hasMore"] == false || rawItems.isNotEmpty() && next == previousCursor)
            require(policies.size <= 64 && receipts.size <= 128 && nowMillis() >= integer(journal, "observedAt"))
            staged["policies"] = policies
            staged["receipts"] = receipts
            staged["cursor"] = next
            staged["observedAt"] = nowMillis()
            check(gate.current(identity) {
                persist(staged)
                apply(scope, compacts(staged))
            })
            journal = staged
            flush(identity, journal, scope, credential)
            if(page["hasMore"] == false) return
        }
    }
    private fun restore(scope: AssistedScope): MutableMap<String, Any?> {
        val raw = persistence.read().also { expectedRaw = it } ?: return empty(scope)
        require(raw.length <= 8388608)
        val journal = JSONObjectUtils.parse(raw)
        if(journal["tenantId"] != scope.tenantId || journal["deviceId"] != scope.deviceId ||
            journal["registrationId"] != scope.registrationId) return empty(scope)
        require(integer(journal, "cursor") >= 0 && integer(journal, "observedAt") <= nowMillis())
        val policies = objectMap(journal["policies"])
        require(policies.size <= 64 && (journal["receipts"] as List<*>).size <= 128)
        for((policy, compact) in policies) {
            val value = verifier.verifyEnvelope(compact as String, scope, nowMillis(), true) ?: error("STORAGE_INVALID")
            require(value["policyId"] == policy && integer(value, "cursor") <= integer(journal, "cursor"))
        }
        return journal
    }
    private fun empty(scope: AssistedScope): MutableMap<String, Any?> = mutableMapOf(
        "tenantId" to scope.tenantId, "deviceId" to scope.deviceId, "registrationId" to scope.registrationId,
        "cursor" to 0L, "observedAt" to 0L, "policies" to emptyMap<String, Any?>(), "receipts" to emptyList<Any>())
    private fun compacts(journal: Map<String, Any?>) = objectMap(journal["policies"]).values.map { it as String }
    private fun persist(journal: Map<String, Any?>) {
        val raw = JSONObjectUtils.toJSONString(journal)
        require(raw.length <= 8388608)
        // The enclosing identity gate serializes writers across service restarts.
        // A cancelled executor may still return; its old journal cannot overwrite
        // a newer coordinator's cursor or replayable receipt intents.
        check(persistence.read() == expectedRaw)
        persistence.write(raw)
        check(persistence.read() == raw)
        expectedRaw = raw
    }
    private fun flush(identity: IdentityLease, journal: MutableMap<String, Any?>, scope: AssistedScope, credential: String) {
        val receipts = (journal["receipts"] as List<*>).map { objectMap(it) }.toMutableList()
        while(receipts.isNotEmpty()) {
            val receipt = receipts.first()
            val compact = receipt["compact"] as String
            val envelope = verifier.verifyEnvelope(compact, scope, nowMillis(), true) ?: error("STORAGE_INVALID")
            require(uuid(receipt["receiptId"]) && receipt["deliveryId"] == envelope["deliveryId"] &&
                integer(receipt, "cursor") == integer(envelope, "cursor") && receipt["envelopeHash"] == hash(compact) &&
                receipt["stage"] == "STORED")
            check(gate.current(identity) { })
            val response = transport.request("POST", "configuration-receipts", credential, receipt.filterKeys { it != "compact" })
            if(response.status != 200) throw BackgroundHttpFailure(response.status)
            val ack = response.body
            require(ack["id"] == receipt["receiptId"] && ack["evidenceStatus"] == "DEVICE_REPORT_NOT_EXECUTION" &&
                ack["historical"] is Boolean && integer(ack, "receivedAt") >= 0 &&
                ack["state"] in setOf("SERVED", "DEVICE_REPORTED_RECEIVED", "DEVICE_REPORTED_STORED",
                    "DEVICE_REPORTED_REJECTED", "SUPERSEDED", "EXPIRED_ATTEMPT") &&
                (ack["historical"] == true || ack["state"] == "DEVICE_REPORTED_STORED"))
            receipts.removeAt(0)
            journal["receipts"] = receipts
            check(gate.current(identity) { persist(journal) })
        }
    }
    private fun hash(compact: String) = MessageDigest.getInstance("SHA-256").digest(compact.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 255) }
}
