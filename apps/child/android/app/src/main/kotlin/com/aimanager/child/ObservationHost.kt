package com.aimanager.child

import android.app.Activity
import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.UserManager
import android.provider.Settings
import java.security.MessageDigest
import java.util.TimeZone
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** 官方系统查询适配。只查当前用户可见启动应用；不读取事件、网页、摄像头或其他资料。 */
class ObservationHost(private val activity: Activity) : AndroidObservationApi {
    private val context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue(8))
    @Volatile private var closed = false

    private fun failure(code: String) = FlutterError(code)
    private fun <T> query(callback: (Result<T>) -> Unit, operation: () -> T) {
        if (closed) { callback(Result.failure(failure("OBSERVATION_NATIVE_UNAVAILABLE"))); return }
        try {
            worker.execute {
                val result = try {
                    if (closed) throw failure("OBSERVATION_NATIVE_UNAVAILABLE")
                    Result.success(operation())
                } catch (error: FlutterError) { Result.failure(error) }
                catch (_: SecurityException) { Result.failure(failure("OBSERVATION_ACCESS_DENIED")) }
                catch (_: Exception) { Result.failure(failure("OBSERVATION_NATIVE_FAILED")) }
                main.post { callback(result) }
            }
        } catch (_: RejectedExecutionException) {
            callback(Result.failure(failure("OBSERVATION_NATIVE_BUSY")))
        }
    }

    private fun userManager(): UserManager = context.getSystemService(UserManager::class.java)
        ?: throw failure("OBSERVATION_NATIVE_UNAVAILABLE")
    private fun profile(): String {
        val user = userManager()
        // isManagedProfile 的公开无参 API 从 API 30 起可用；旧版本不猜工作资料身份。
        if (Build.VERSION.SDK_INT >= 30 && user.isManagedProfile) return "WORK"
        if (Build.VERSION.SDK_INT >= 33 && user.isProfile) return "UNKNOWN"
        if (Build.VERSION.SDK_INT >= 31 && UserManager.isHeadlessSystemUserMode()) return "UNKNOWN"
        if (user.isSystemUser) return "PRIMARY"
        return if (Build.VERSION.SDK_INT >= 30) "SECONDARY" else "UNKNOWN"
    }
    @Suppress("DEPRECATION")
    private fun usageMode(): Int? {
        val ops = context.getSystemService(AppOpsManager::class.java) ?: return null
        return if (Build.VERSION.SDK_INT in 29..35)
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        else ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
    }
    private fun usageGranted(): Boolean = usageMode() == AppOpsManager.MODE_ALLOWED
    private fun facts(): NativeObservationFacts {
        val mode = usageMode()
        val supported = mode != null && context.getSystemService(UsageStatsManager::class.java) != null
        val grant = if (!supported) "NOT_APPLICABLE" else when (mode) {
            AppOpsManager.MODE_ALLOWED -> "GRANTED"
            AppOpsManager.MODE_DEFAULT -> "NOT_REQUESTED"
            else -> "DENIED"
        }
        return NativeObservationFacts(usageGranted = supported && mode == AppOpsManager.MODE_ALLOWED,
            usageSupported = supported, usageGrantStatus = grant, unlocked = userManager().isUserUnlocked,
            television = context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK), profile = profile())
    }

    override fun inspect(callback: (Result<NativeObservationFacts>) -> Unit) = query(callback) { facts() }

    @Suppress("DEPRECATION")
    private fun launchable(): List<String> {
        if (!userManager().isUserUnlocked) throw failure("OBSERVATION_DEVICE_LOCKED")
        val packages = linkedSetOf<String>()
        for (category in listOf(Intent.CATEGORY_LAUNCHER, Intent.CATEGORY_LEANBACK_LAUNCHER)) {
            for (entry in context.packageManager.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0)) {
                val name = entry.activityInfo?.packageName ?: throw failure("OBSERVATION_SAMPLE_INVALID")
                if (name.length > 255 || !name.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")))
                    throw failure("OBSERVATION_SAMPLE_INVALID")
                packages.add(name)
                if (packages.size > 500) throw failure("OBSERVATION_LIMIT_EXCEEDED")
            }
        }
        return packages.sorted()
    }
    private fun label(name: String): String {
        val info = context.packageManager.getApplicationInfo(name, 0)
        var label = context.packageManager.getApplicationLabel(info).toString()
            .replace(Regex("[\\x00-\\x1f\\x7f\\u202a-\\u202e\\u2066-\\u2069]"), " ").trim().take(100)
        if (label.isNotEmpty() && Character.isHighSurrogate(label.last())) label = label.dropLast(1)
        return label.ifEmpty { name.take(100) }
    }
    @Suppress("DEPRECATION")
    private fun signingDigests(info: PackageInfo): List<String?> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        val values = signatures?.map { signature ->
            MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        }?.distinct()?.sorted() ?: emptyList()
        if (values.size > 8) throw failure("OBSERVATION_LIMIT_EXCEEDED")
        return values
    }
    @Suppress("DEPRECATION")
    override fun inventory(callback: (Result<List<NativeObservedApplication?>>) -> Unit) = query(callback) {
        val currentProfile = profile()
        launchable().map { name ->
            val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
            val info = context.packageManager.getPackageInfo(name, flags)
            val version = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
            if (version < 0 || version > 9007199254740991L) throw failure("OBSERVATION_SAMPLE_INVALID")
            NativeObservedApplication(name, label(name), currentProfile, signingDigests(info), version,
                ((info.applicationInfo?.flags ?: 0) and (android.content.pm.ApplicationInfo.FLAG_SYSTEM or
                    android.content.pm.ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0)
        }
    }

    override fun usage(queryStart: Long, queryEnd: Long, callback: (Result<NativeUsageSample>) -> Unit) = query(callback) {
        val now = System.currentTimeMillis()
        if (queryStart <= 0 || queryStart >= queryEnd || queryEnd - queryStart > 2 * 86400000L || queryEnd > now + 300000L)
            throw failure("OBSERVATION_SAMPLE_INVALID")
        if (!userManager().isUserUnlocked) throw failure("OBSERVATION_DEVICE_LOCKED")
        if (!usageGranted()) throw failure("USAGE_ACCESS_NOT_GRANTED")
        val visible = launchable().toSet()
        val manager = context.getSystemService(UsageStatsManager::class.java) ?: throw failure("OBSERVATION_NATIVE_UNAVAILABLE")
        val stats = manager.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, queryStart, queryEnd)
            ?: throw failure("OBSERVATION_USAGE_UNAVAILABLE")
        val records = mutableListOf<NativeUsageEntry?>()
        val keys = hashSetOf<String>()
        for (entry in stats) {
            // 不报告不可见应用或零时长项；空列表不证明整台设备没有使用。
            if (!visible.contains(entry.packageName) || entry.totalTimeInForeground == 0L) continue
            if (entry.firstTimeStamp <= 0 || entry.firstTimeStamp > entry.lastTimeStamp ||
                entry.firstTimeStamp < now - 7 * 86400000L || entry.lastTimeStamp > now + 300000L ||
                entry.totalTimeInForeground < 0 || entry.totalTimeInForeground > entry.lastTimeStamp - entry.firstTimeStamp ||
                !keys.add("${entry.packageName}|${entry.firstTimeStamp}|${entry.lastTimeStamp}"))
                throw failure("OBSERVATION_SAMPLE_INVALID")
            records.add(NativeUsageEntry(entry.packageName, label(entry.packageName), entry.firstTimeStamp,
                entry.lastTimeStamp, entry.totalTimeInForeground))
            if (records.size > 500) throw failure("OBSERVATION_LIMIT_EXCEEDED")
        }
        if (!usageGranted() || !userManager().isUserUnlocked) throw failure("USAGE_ACCESS_NOT_GRANTED")
        NativeUsageSample(queryStart, queryEnd, System.currentTimeMillis(), TimeZone.getDefault().id, profile(), records)
    }

    override fun openUsageSettings(callback: (Result<Unit>) -> Unit) {
        if (closed || activity.isFinishing || activity.isDestroyed) {
            callback(Result.failure(failure("OBSERVATION_SETTINGS_UNAVAILABLE"))); return
        }
        try {
            try { activity.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS, Uri.parse("package:${context.packageName}"))) }
            catch (_: ActivityNotFoundException) { activity.startActivity(Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)) }
            callback(Result.success(Unit))
        } catch (_: Exception) { callback(Result.failure(failure("OBSERVATION_SETTINGS_UNAVAILABLE"))) }
    }
    fun close() { closed = true; worker.shutdown() }
}
