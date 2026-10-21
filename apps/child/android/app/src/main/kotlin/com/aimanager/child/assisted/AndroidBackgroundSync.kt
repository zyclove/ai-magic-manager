package com.aimanager.child.assisted

import android.content.Context
import com.aimanager.child.BuildConfig
import com.it_nomads.fluttersecurestorage.ChildIdentityStorage
import com.nimbusds.jose.util.JSONObjectUtils
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import javax.net.ssl.HttpsURLConnection

/** Shared by Flutter storage calls and the native service in this process. */
object AndroidIdentityGate {
    @Volatile private var instance: DurableIdentityGate? = null
    private var storage: ChildIdentityStorage? = null
    fun get(context: Context): DurableIdentityGate = instance ?: synchronized(this) {
        instance ?: run {
            val sdk = ChildIdentityStorage(context.applicationContext)
            storage = sdk
            DurableIdentityGate(object : IdentityPersistence {
                override fun read() = sdk.readIdentity()
                override fun write(value: String?) = sdk.writeIdentity(value)
            }, { before, after ->
                val previous = before?.let { JSONObjectUtils.parse(it) }
                val current = after?.let { JSONObjectUtils.parse(it) }
                if(current == null || current["authenticationBlocked"] == true || current["phase"] == "cleanupPending" ||
                    listOf("tenantId", "deviceId", "registrationId").any { previous?.get(it) != current[it] }) {
                    check(context.getSharedPreferences("family_background_sync_v1", Context.MODE_PRIVATE).edit().clear().commit())
                    check(AssistedRuntimeHost.get(context).clear())
                    sdk.writeObservation(null)
                }
            }).also { instance = it }
        }
    }
    fun observationRead(context: Context): String? = get(context).coordinate { storage!!.readObservation() }
    fun observationCompareAndSet(context: Context, expected: String?, replacement: String?): Boolean {
        val gate = get(context)
        return gate.coordinate {
            if(storage!!.readObservation() != expected) return@coordinate false
            if(replacement != null) {
                val state = gate.read()?.let { JSONObjectUtils.parse(it) } ?: return@coordinate false
                if(state["authenticationBlocked"] == true || state["phase"] !in
                    setOf("active", "rotationRequested", "rotationPending", "activationUncertain")) return@coordinate false
                val value = JSONObjectUtils.parse(replacement)
                if(value["scope"] != listOf("tenantId", "deviceId", "registrationId").joinToString(".") { state[it] as String })
                    return@coordinate false
            }
            storage!!.writeObservation(replacement)
            true
        }
    }
}

internal class AndroidBackgroundConfigurationJournal(context: Context, gate: DurableIdentityGate,
    transport: BackgroundTransport, host: AssistedRuntimeHost) : BackgroundConfigurations {
    private val preferences = context.applicationContext.getSharedPreferences("family_background_sync_v1", Context.MODE_PRIVATE)
    private val journal = AssistedConfigurationJournal(gate, object : BackgroundJournalPersistence {
        override fun read() = preferences.getString("journal", null)
        override fun write(value: String?) {
            val editor = preferences.edit()
            if(value == null) editor.clear() else editor.putString("journal", value)
            check(editor.commit())
        }
    }, transport, AssistedConfigurationVerifier(BuildConfig.CONFIGURATION_ISSUER, BuildConfig.CONFIGURATION_JWKS),
        { scope, compacts -> host.acceptBackground(scope, compacts) }, System::currentTimeMillis)
    override fun clear() = journal.clear()
    override fun synchronize(identity: IdentityLease, scope: AssistedScope, credential: String) =
        journal.synchronize(identity, scope, credential)
}

/** Does not create a service, grant a permission, hold a wake lock or bypass Doze. */
internal class AndroidBackgroundSync(private val context: Context) {
    private var executor: ScheduledExecutorService? = null
    @Synchronized fun start() {
        if (executor != null || BuildConfig.CHILD_API_ROOT.isBlank()) return
        val transport = try { InstalledBackgroundTransport(BuildConfig.CHILD_API_ROOT) } catch (_: Exception) { return }
        val gate = AndroidIdentityGate.get(context)
        val host = AssistedRuntimeHost.get(context)
        val runtime = object : BackgroundRuntime {
            override fun clear() { check(host.clear()) }
            override fun snapshot() = host.inspect()
        }
        val journal = AndroidBackgroundConfigurationJournal(context, gate, transport, host)
        val usage = AssistedUsageSynchronizer(gate, object : UsageJournalStore {
            override fun read() = AndroidIdentityGate.observationRead(context)
            override fun compareAndSet(expected: String?, replacement: String?) =
                AndroidIdentityGate.observationCompareAndSet(context, expected, replacement)
        }, AndroidUsageSource(context), transport, System::currentTimeMillis)
        val sync = AssistedBackgroundSync(gate, transport, journal, runtime,
            BuildConfig.CHILD_API_ROOT.removeSuffix("/"), usage = usage, nowMillis = System::currentTimeMillis)
        executor = Executors.newSingleThreadScheduledExecutor().also {
            it.scheduleWithFixedDelay({ sync.cycle() }, 0, 30, TimeUnit.SECONDS)
        }
    }
    @Synchronized fun stop() { executor?.shutdownNow(); executor = null }
    companion object {
        /** Cleanup takes the identity lock before either runtime/cache lock. */
        fun clear(context: Context): Boolean = try {
            val gate = AndroidIdentityGate.get(context)
            val lease = gate.lease()
            var success = false
            gate.current(lease) {
                success = context.getSharedPreferences("family_background_sync_v1", Context.MODE_PRIVATE).edit().clear().commit() &&
                    AssistedRuntimeHost.get(context).clear()
            } && success
        } catch (_: Exception) { false }
        fun invoke(context: Context, activity: android.app.Activity, method: String, arguments: Any?): Map<String, Any?> {
            val gate = AndroidIdentityGate.get(context)
            val lease = gate.lease()
            val state = lease.raw?.let { JSONObjectUtils.parse(it) }
            require(state != null && state["authenticationBlocked"] != true && state["phase"] in
                setOf("active", "rotationRequested", "rotationPending", "activationUncertain"))
            if(method == "acceptSignedConfigurations") {
                val args = arguments as Map<*, *>
                require(listOf("tenantId", "deviceId", "registrationId").all { state[it] == args[it] })
            }
            var output: Map<String, Any?>? = null
            check(gate.current(lease) { output = AssistedRuntimeHost.get(context).invoke(activity, method, arguments) })
            return output!!
        }
    }
}
