package com.aimanager.child.assisted

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Process
import android.os.UserManager
import java.util.Calendar
import java.util.TimeZone

/** Aggregated UsageStats only, launcher-visible packages, current Android user. */
internal class AndroidUsageSource(context: Context) : NativeUsageSource {
    private val context = context.applicationContext
    @Suppress("DEPRECATION") override fun inspect(): NativeUsageFacts {
        val user = context.getSystemService(UserManager::class.java) ?: return NativeUsageFacts(false, false, false, "UNKNOWN")
        val ops = context.getSystemService(AppOpsManager::class.java)
        val usage = context.getSystemService(UsageStatsManager::class.java)
        val mode = if(Build.VERSION.SDK_INT in 29..35) ops?.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
            else ops?.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        val profile = when {
            Build.VERSION.SDK_INT >= 30 && user.isManagedProfile -> "WORK"
            Build.VERSION.SDK_INT >= 33 && user.isProfile -> "UNKNOWN"
            Build.VERSION.SDK_INT >= 31 && UserManager.isHeadlessSystemUserMode() -> "UNKNOWN"
            user.isSystemUser -> "PRIMARY"
            Build.VERSION.SDK_INT >= 30 -> "SECONDARY"
            else -> "UNKNOWN"
        }
        return NativeUsageFacts(mode == AppOpsManager.MODE_ALLOWED, user.isUserUnlocked, mode != null && usage != null, profile)
    }
    @Suppress("DEPRECATION") override fun sample(): Map<String, Any?> {
        val facts = inspect()
        check(facts.granted && facts.unlocked && facts.supported)
        val now = System.currentTimeMillis()
        val start = Calendar.getInstance().apply { timeInMillis = now; set(Calendar.HOUR_OF_DAY, 0); set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0); set(Calendar.MILLISECOND, 0) }.timeInMillis
        require(start in 1 until now)
        val visible = linkedSetOf<String>()
        for(category in listOf(Intent.CATEGORY_LAUNCHER, Intent.CATEGORY_LEANBACK_LAUNCHER)) {
            context.packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0).forEach {
                val name = it.activityInfo.packageName
                require(name.length <= 255 && name.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")))
                visible.add(name); require(visible.size <= 500)
            }
        }
        val stats = context.getSystemService(UsageStatsManager::class.java)?.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, start, now)
            ?: error("USAGE_STATS_UNAVAILABLE")
        val applications = stats.filter { it.packageName in visible && it.totalTimeInForeground > 0 }.map { entry ->
            val label = context.packageManager.getApplicationLabel(context.packageManager.getApplicationInfo(entry.packageName, 0))
                .toString().replace(Regex("[\\x00-\\x1f\\x7f\\u202a-\\u202e\\u2066-\\u2069]"), " ").trim().take(100)
                .let { if(it.isNotEmpty() && Character.isHighSurrogate(it.last())) it.dropLast(1) else it }.ifBlank { entry.packageName.take(100) }
            mapOf("packageName" to entry.packageName, "displayName" to label, "firstTimeStamp" to entry.firstTimeStamp,
                "lastTimeStamp" to entry.lastTimeStamp, "foregroundMillis" to entry.totalTimeInForeground)
        }.sortedWith(compareBy({ it["packageName"] as String }, { it["firstTimeStamp"] as Long }, { it["lastTimeStamp"] as Long }))
        require(applications.size <= 500)
        val after = inspect()
        check(after.granted && after.unlocked && after.supported && after.profile == facts.profile)
        return mapOf("queryStart" to start, "queryEnd" to now, "observedAt" to System.currentTimeMillis(),
            "timeZone" to TimeZone.getDefault().id, "profile" to facts.profile, "applications" to applications)
    }
}
