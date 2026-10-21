package com.aimanager.child.assisted

import android.app.Activity
import android.app.AppOpsManager
import android.app.KeyguardManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import android.telecom.TelecomManager
import com.aimanager.child.BuildConfig
import org.json.JSONObject

/** App-private, signed assistance only. No device-owner/admin privileges. */
internal class AssistedRuntimeHost(context: Context) {
    private val context = context.applicationContext
    private val preferences = this.context.getSharedPreferences("family_assistance_v1", Context.MODE_PRIVATE)
    private val verifier = AssistedConfigurationVerifier(BuildConfig.CONFIGURATION_ISSUER, BuildConfig.CONFIGURATION_JWKS)
    private val evaluator = AssistedEvaluator()
    private var intervention = AssistedInterventionTracker()
    private var latest: AssistedResult? = null
    private var persistenceFailed = false
    private var lastUsagePackage: String? = null

    private fun scope(): AssistedScope? = try {
        AssistedScope(preferences.getString("tenantId", null)!!,
            preferences.getString("deviceId", null)!!, preferences.getString("registrationId", null)!!)
    } catch (_: Exception) { null }

    private fun saved(): SignedAssistedConfiguration? {
        val scope = scope() ?: return null
        val compact = preferences.getString("compact", null) ?: return null
        return verifier.verify(compact, scope, System.currentTimeMillis(), restoration = true)
    }

    @Synchronized fun invoke(activity: Activity, method: String, arguments: Any?): Map<String, Any?> {
        val args = arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        when (method) {
            "acceptSignedConfigurations" -> accept(args)
            "setConsent" -> {
                require(args["enabled"] is Boolean)
                persistenceFailed = !preferences.edit().putBoolean("consent", args["enabled"] == true).commit()
                latest = null
            }
            "clear" -> clear()
            "openUsageSettings" -> activity.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS))
            "openAccessibilitySettings" -> activity.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
            "inspect" -> Unit
            else -> throw IllegalArgumentException("Unknown assistance operation")
        }
        return inspect()
    }

    private fun accept(args: Map<*, *>, restoration: Boolean = false) {
        val nextScope = AssistedScope(args["tenantId"] as String, args["deviceId"] as String,
            args["registrationId"] as String)
        val compacts = args["configurations"] as List<*>
        require(compacts.size <= 64)
        require(compacts.sumOf { (it as String).length.toLong() } <= 8388608L)
        val previousScope = scope()
        val previous = saved()
        val previousCompact = preferences.getString("compact", null)
        val previousHead = previousCompact?.let { verifier.verifyEnvelope(it, nextScope, System.currentTimeMillis(), true) }
        if(previousScope != null && previousScope != nextScope) {
            check(clear())
        }
        val candidates = compacts.mapNotNull { raw ->
            val compact = raw as String
            verifier.verify(compact, nextScope, System.currentTimeMillis(),
                restoration = restoration || previous?.compact == compact)
        }.filter { candidate -> candidate.rules != null || candidate.policyId == previousHead?.get("policyId") ||
            (verifier.verifyEnvelope(candidate.compact, nextScope, System.currentTimeMillis(), true)
                ?.get("document") as? Map<*, *>)?.containsKey("familyAssistance") == true }
        if (candidates.size != 1) {
            // A stale Flutter journal or an unrelated institutional policy must
            // not erase a newer native stream. Explicit signed replacement of
            // the current policy, or ambiguous family streams, removes authority.
            val replacement = compacts.firstOrNull { raw ->
                val envelope = verifier.verifyEnvelope(raw as String, nextScope, System.currentTimeMillis(), restoration)
                previousHead != null && envelope != null && envelope["policyId"] == previousHead["policyId"] &&
                    (envelope["sourceSequence"] as Number).toLong() > (previousHead["sourceSequence"] as Number).toLong() &&
                    verifier.permitsReplacement(previousCompact, raw, nextScope, System.currentTimeMillis())
            }
            if(candidates.size > 1 || replacement != null) {
                // Keep a signed generic/removal head as the sequence floor.
                // saved() cannot turn it into family rules, while older Flutter
                // caches still cannot resurrect the preceding family stream.
                val editor = preferences.edit()
                if(replacement != null) editor.putString("compact", replacement as String)
                else editor.remove("compact")
                persistenceFailed = !editor.commit()
                latest = null
            }
            return
        }
        val next = candidates.single()
        if(previousScope == nextScope && !verifier.permitsReplacement(previousCompact, next.compact, nextScope, System.currentTimeMillis())) return
        if (previous != null && previous.scope == next.scope) {
            require(previous.policyId == next.policyId)
            // Foreground and background journals can advance independently.
            // An older cached stream cannot stall the next authenticated pull.
            if(next.sourceSequence < previous.sourceSequence) return
            require(next.sourceSequence != previous.sourceSequence ||
                (next.versionId == previous.versionId && next.rules == previous.rules))
        }
        val editor = preferences.edit().putString("compact", next.compact)
            .putString("tenantId", next.scope.tenantId).putString("deviceId", next.scope.deviceId)
            .putString("registrationId", next.scope.registrationId)
        if (previousScope != next.scope) {
            editor.putBoolean("consent", false).remove("checkpoint")
        }
        persistenceFailed = !editor.commit()
        latest = null
    }

    @Synchronized fun acceptBackground(scope: AssistedScope, compacts: List<String>) = accept(mapOf(
        "tenantId" to scope.tenantId, "deviceId" to scope.deviceId, "registrationId" to scope.registrationId,
        "configurations" to compacts), restoration = true)

    @Synchronized fun clear(): Boolean {
        latest = null
        intervention = AssistedInterventionTracker()
        persistenceFailed = !preferences.edit().clear().commit()
        return !persistenceFailed
    }

    private fun checkpoint(): AssistedCheckpoint? = try {
        val value = JSONObject(preferences.getString("checkpoint", null)!!)
        AssistedCheckpoint(value.getString("day"), value.getLong("used"), value.getLong("wall"),
            value.getLong("elapsed"), value.getInt("boot"), value.optString("foreground").takeIf { it.isNotBlank() },
            value.getString("policy"), value.getLong("version"), value.getBoolean("trusted"),
            value.getLong("anchorWall"), value.getLong("anchorElapsed"))
    } catch (_: Exception) {
        if (preferences.contains("checkpoint")) persistenceFailed = true
        null
    }

    private fun persist(value: AssistedCheckpoint): Boolean = preferences.edit().putString("checkpoint", JSONObject()
        .put("day", value.dayKey).put("used", value.usedMillis).put("wall", value.wallMillis)
        .put("elapsed", value.elapsedMillis).put("boot", value.bootCount).put("foreground", value.foregroundPackage ?: "")
        .put("policy", value.policyId).put("version", value.policyVersion).put("trusted", value.trusted)
        .put("anchorWall", value.clockAnchorWallMillis).put("anchorElapsed", value.clockAnchorElapsedMillis).toString()).commit()

    @Suppress("DEPRECATION") private fun usageGranted(): Boolean = try {
        val ops = context.getSystemService(AppOpsManager::class.java)
        val mode = if (Build.VERSION.SDK_INT >= 29)
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        else ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        mode == AppOpsManager.MODE_ALLOWED
    } catch (_: Exception) { false }

    @Suppress("DEPRECATION") fun safePackages(): Set<String> {
        val safe = mutableSetOf(context.packageName, "com.android.settings", "com.android.systemui",
            "com.android.phone", "com.android.emergency", "com.android.server.telecom",
            "com.google.android.dialer", "com.android.dialer", "com.google.android.permissioncontroller",
            "com.android.permissioncontroller", "com.samsung.android.dialer", "com.samsung.android.incallui")
        fun resolved(intent: Intent) {
            context.packageManager.queryIntentActivities(intent, 0).forEach { safe.add(it.activityInfo.packageName) }
        }
        resolved(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME))
        resolved(Intent(Settings.ACTION_SETTINGS))
        resolved(Intent(Intent.ACTION_DIAL))
        context.getSystemService(TelecomManager::class.java)?.defaultDialerPackage?.let { safe.add(it) }
        context.getSystemService(TelecomManager::class.java)?.systemDialerPackage?.let { safe.add(it) }
        return safe
    }

    /** Package-only usage events corroborate the accessibility foreground. */
    @Suppress("DEPRECATION") private fun corroborated(packageName: String?): String? {
        if (!usageGranted()) return null
        val now = System.currentTimeMillis()
        return try {
            val events = context.getSystemService(UsageStatsManager::class.java)
                ?.queryEvents(now - 15000L, now) ?: return null
            val event = UsageEvents.Event()
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                when (event.eventType) {
                    UsageEvents.Event.MOVE_TO_FOREGROUND -> lastUsagePackage = event.packageName
                    UsageEvents.Event.MOVE_TO_BACKGROUND -> if (lastUsagePackage == event.packageName) lastUsagePackage = null
                }
            }
            packageName.takeIf { it == lastUsagePackage || it in safePackages() }
        } catch (_: Exception) { null }
    }

    /** Persist before returning any restriction decision; missed observation fails open. */
    @Synchronized fun observe(packageName: String?, identityScope: AssistedScope? = scope()): AssistedResult {
        val signed = saved()
        val unlocked = context.getSystemService(KeyguardManager::class.java)?.isKeyguardLocked != true &&
            context.getSystemService(android.os.PowerManager::class.java)?.isInteractive == true
        val checkpoint = checkpoint()
        val result = evaluator.update(AssistedInput(signed?.rules, checkpoint, corroborated(packageName).takeIf { unlocked },
            System.currentTimeMillis(), SystemClock.elapsedRealtime(),
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1),
            usageGranted() && FamilyAccessibilityService.connected,
            preferences.getBoolean("consent", false), !persistenceFailed && signed?.rules != null &&
                signed.scope == identityScope, safePackages()))
        if (result.checkpoint != null && !persist(result.checkpoint)) {
            persistenceFailed = true
            latest = result.copy(decision = AssistedDecision.ALLOW, status = AssistedStatus.CONFIGURATION_INVALID,
                reason = "checkpoint_storage_failed")
        } else latest = result
        return latest!!
    }

    @Synchronized fun inspect(): Map<String, Any?> {
        val signed = saved()
        val consent = preferences.getBoolean("consent", false)
        val usage = usageGranted()
        val connected = FamilyAccessibilityService.connected
        val recent = latest?.takeIf {
            val checkpoint = it.checkpoint
            checkpoint != null && SystemClock.elapsedRealtime() - checkpoint.elapsedMillis in 0..15000L
        }
        val health = when {
            persistenceFailed -> "STORAGE_FAILURE"
            !consent -> "CONSENT_REQUIRED"
            !usage || !connected -> "PERMISSION_MISSING"
            signed?.rules == null -> "CONFIGURATION_UNAVAILABLE"
            recent == null -> "NATIVE_OBSERVATION_UNAVAILABLE"
            else -> recent.status.name
        }
        val actual = recent?.takeIf { health == "ACTIVE" }
        val reportSequence = preferences.getLong("reportSequence", 0L) + 1L
        if (!preferences.edit().putLong("reportSequence", reportSequence).commit()) persistenceFailed = true
        return mapOf("health" to health, "limitStatus" to (actual?.decision?.name ?: "UNKNOWN"),
            "reason" to (recent?.reason ?: health.lowercase()), "remainingSeconds" to actual?.remainingSeconds,
            "observedAt" to System.currentTimeMillis(), "optedIn" to consent, "usageGranted" to usage,
            "accessibilityConnected" to connected, "systemEnforced" to false,
            "tenantId" to signed?.scope?.tenantId, "deviceId" to signed?.scope?.deviceId,
            "registrationId" to signed?.scope?.registrationId, "policyId" to signed?.policyId,
            "versionId" to signed?.versionId, "sourceSequence" to signed?.sourceSequence,
            "reportSequence" to reportSequence,
            "manufacturer" to Build.MANUFACTURER.filter { !it.isISOControl() }.take(100),
            "model" to Build.MODEL.filter { !it.isISOControl() }.take(100),
            "apiLevel" to Build.VERSION.SDK_INT,
            "interventionStatus" to intervention.status(signed, SystemClock.elapsedRealtime()))
    }

    @Synchronized fun actionResult(succeeded: Boolean) {
        val configuration = saved() ?: return
        intervention.record(configuration, SystemClock.elapsedRealtime(), succeeded)
        if (!succeeded) latest = latest?.copy(decision = AssistedDecision.ALLOW,
            status = AssistedStatus.CONFIGURATION_INVALID, reason = "home_action_failed")
    }

    companion object {
        @Volatile private var instance: AssistedRuntimeHost? = null
        fun get(context: Context): AssistedRuntimeHost = instance ?: synchronized(this) {
            instance ?: AssistedRuntimeHost(context).also { instance = it }
        }
    }
}
