package com.aimanager.child.assisted

import java.util.Calendar
import java.util.GregorianCalendar
import java.util.Locale
import java.util.TimeZone
import kotlin.math.abs
import kotlin.math.min

/** Cached, verified FAMILY rules. lockedPackages are metered targets, not an unconditional denylist. */
data class AssistedRules(
    val policyId: String,
    val policyVersion: Long,
    val dailyAllowanceSeconds: Long,
    val timezoneId: String,
    val lockedPackages: Set<String>,
    val schedules: List<AssistedSchedule>,
    val validUntilEpochMillis: Long,
    val exceptionUntilEpochMillis: Long? = null,
)

/** Allowed-use window: ISO weekdays (Monday = 1), inclusive start, exclusive end. */
data class AssistedSchedule(val daysOfWeek: Set<Int>, val startMinute: Int, val endMinute: Int)

data class AssistedCheckpoint(
    val dayKey: String,
    val usedMillis: Long,
    val wallMillis: Long,
    val elapsedMillis: Long,
    val bootCount: Int,
    /** Previous metered foreground only; null for safe/unmanaged apps or unavailable observation. */
    val foregroundPackage: String?,
    val policyId: String,
    val policyVersion: Long,
    val trusted: Boolean,
    val clockAnchorWallMillis: Long = wallMillis,
    val clockAnchorElapsedMillis: Long = elapsedMillis,
)

data class AssistedInput(
    val rules: AssistedRules?,
    val checkpoint: AssistedCheckpoint?,
    val observedPackage: String?,
    val wallMillis: Long,
    val elapsedMillis: Long,
    val bootCount: Int,
    val permissionsGranted: Boolean,
    val enabled: Boolean,
    val configurationValid: Boolean,
    val safePackages: Set<String> = emptySet(),
)

enum class AssistedDecision { ALLOW, RESTRICT }
enum class AssistedStatus {
    ACTIVE, DISABLED, PERMISSION_MISSING, CONFIGURATION_INVALID, EXPIRED,
    INITIALIZING, CLOCK_ANOMALY, FOREGROUND_UNAVAILABLE,
}

data class AssistedResult(
    val decision: AssistedDecision,
    val status: AssistedStatus,
    val checkpoint: AssistedCheckpoint?,
    val usedMillis: Long,
    val remainingSeconds: Long,
    val reason: String,
)

class AssistedEvaluator {
    /**
     * The caller persists every returned checkpoint before applying the assisted decision.
     * This is a local, bypassable aid; it does not claim Android system enforcement.
     */
    fun update(input: AssistedInput): AssistedResult {
        val rules = input.rules
        if (!input.configurationValid || rules == null || !validRules(rules)) {
            return unavailable(input, AssistedStatus.CONFIGURATION_INVALID, "configuration_invalid")
        }
        val previous = input.checkpoint
        if (previous != null && (rules.policyVersion < previous.policyVersion ||
                (rules.policyVersion == previous.policyVersion && rules.policyId != previous.policyId))) {
            return unavailable(input, AssistedStatus.CONFIGURATION_INVALID, "stale_configuration")
        }
        val timezone = TimeZone.getTimeZone(rules.timezoneId)
        if (input.wallMillis <= 0 || input.elapsedMillis < 0 || input.bootCount < 0) {
            return unavailable(input, AssistedStatus.CLOCK_ANOMALY, "invalid_clock_sample")
        }
        val today = calendar(input.wallMillis, timezone)
        val todayKey = dayKey(today)
        val fresh = previous == null || rules.policyVersion > previous.policyVersion
        val timelineIssue = previous?.let { timelineIssue(it, input, timezone) }
        if (!fresh && (previous?.trusted != true || timelineIssue != null)) {
            return unavailable(input, AssistedStatus.CLOCK_ANOMALY,
                timelineIssue ?: "runtime_untrusted")
        }

        // A newer server sequence restores trust, but cannot reset today's already-recorded use.
        var used = previous?.takeIf { it.dayKey == todayKey }?.usedMillis?.coerceAtLeast(0) ?: 0
        if (previous?.trusted == true && timelineIssue == null &&
            previous.foregroundPackage != null && previous.foregroundPackage !in input.safePackages) {
            val elapsed = input.elapsedMillis - previous.elapsedMillis
            val charged = if (previous.dayKey == todayKey) elapsed else {
                val midnight = (today.clone() as Calendar).apply {
                    set(Calendar.HOUR_OF_DAY, 0)
                    set(Calendar.MINUTE, 0)
                    set(Calendar.SECOND, 0)
                    set(Calendar.MILLISECOND, 0)
                }.timeInMillis
                val wallDelta = input.wallMillis - previous.wallMillis
                val todayWall = min(wallDelta, input.wallMillis - midnight).coerceAtLeast(0)
                if (wallDelta == 0L) 0 else elapsed * todayWall / wallDelta
            }
            used = if (Long.MAX_VALUE - used < charged) Long.MAX_VALUE else used + charged
        }

        val allowanceMillis = rules.dailyAllowanceSeconds * 1_000
        val remainingMillis = (allowanceMillis - min(allowanceMillis, used)).coerceAtLeast(0)
        val remainingSeconds = (remainingMillis + 999) / 1_000
        val observed = input.observedPackage?.takeIf { it.isNotBlank() }
        val safe = observed != null && observed in input.safePackages
        val target = observed != null && !safe && observed in rules.lockedPackages
        val status = when {
            !input.enabled -> AssistedStatus.DISABLED
            !input.permissionsGranted -> AssistedStatus.PERMISSION_MISSING
            input.wallMillis >= rules.validUntilEpochMillis -> AssistedStatus.EXPIRED
            fresh -> AssistedStatus.INITIALIZING
            observed == null -> AssistedStatus.FOREGROUND_UNAVAILABLE
            else -> AssistedStatus.ACTIVE
        }
        val observing = status == AssistedStatus.ACTIVE || status == AssistedStatus.INITIALIZING
        val checkpoint = AssistedCheckpoint(todayKey, used, input.wallMillis, input.elapsedMillis,
            input.bootCount, observed.takeIf { observing && target }, rules.policyId,
            rules.policyVersion, true,
            if (fresh) input.wallMillis else previous!!.clockAnchorWallMillis,
            if (fresh) input.elapsedMillis else previous!!.clockAnchorElapsedMillis)
        var decision = AssistedDecision.ALLOW
        val reason = when {
            status != AssistedStatus.ACTIVE -> status.name.lowercase(Locale.ROOT)
            safe -> "package_safe"
            !target -> "package_unmanaged"
            rules.exceptionUntilEpochMillis?.let { input.wallMillis < it } == true -> "exception_active"
            used >= allowanceMillis -> {
                decision = AssistedDecision.RESTRICT
                "quota_exhausted"
            }
            !withinSchedule(rules.schedules, today) -> {
                decision = AssistedDecision.RESTRICT
                "outside_schedule"
            }
            else -> "within_rules"
        }
        return AssistedResult(decision, status, checkpoint, used, remainingSeconds, reason)
    }

    private fun validRules(rules: AssistedRules): Boolean =
        rules.policyId.isNotBlank() && rules.policyVersion >= 0 &&
            rules.dailyAllowanceSeconds in 0..86_400 && rules.validUntilEpochMillis > 0 &&
            rules.timezoneId in availableTimezones && rules.lockedPackages.none { it.isBlank() } &&
            rules.schedules.all {
                it.daysOfWeek.isNotEmpty() && it.daysOfWeek.all { day -> day in 1..7 } &&
                    it.startMinute in 0..1439 && it.endMinute in 0..1440 &&
                    it.startMinute != it.endMinute
            }

    private fun timelineIssue(
        previous: AssistedCheckpoint,
        input: AssistedInput,
        timezone: TimeZone,
    ): String? {
        if (previous.usedMillis < 0 || previous.wallMillis <= 0 || previous.elapsedMillis < 0 ||
            previous.bootCount < 0 || previous.clockAnchorWallMillis <= 0 ||
            previous.clockAnchorElapsedMillis < 0 ||
            previous.clockAnchorWallMillis > previous.wallMillis ||
            previous.clockAnchorElapsedMillis > previous.elapsedMillis ||
            previous.dayKey != dayKey(calendar(previous.wallMillis, timezone))) {
            return "checkpoint_invalid"
        }
        if (previous.bootCount != input.bootCount) return "reboot_detected"
        if (input.elapsedMillis < previous.elapsedMillis) return "elapsed_went_backwards"
        if (input.wallMillis < previous.wallMillis) return "clock_went_backwards"
        val elapsed = input.elapsedMillis - previous.elapsedMillis
        val wall = input.wallMillis - previous.wallMillis
        if (elapsed > MAX_OBSERVATION_GAP_MILLIS) return "observation_gap"
        if (abs(wall - elapsed) > CLOCK_TOLERANCE_MILLIS) return "clock_changed"
        val wallFromAnchor = input.wallMillis - previous.clockAnchorWallMillis
        val elapsedFromAnchor = input.elapsedMillis - previous.clockAnchorElapsedMillis
        if (abs(wallFromAnchor - elapsedFromAnchor) > CLOCK_TOLERANCE_MILLIS) return "clock_changed"
        return null
    }

    private fun unavailable(input: AssistedInput, status: AssistedStatus, reason: String): AssistedResult {
        val previous = input.checkpoint
        // Retain the old policy sequence and day during a fault; an untrusted clock cannot reset use.
        val checkpoint = previous?.copy(usedMillis = previous.usedMillis.coerceAtLeast(0),
            wallMillis = input.wallMillis, elapsedMillis = input.elapsedMillis,
            bootCount = input.bootCount, foregroundPackage = null, trusted = false)
        val used = checkpoint?.usedMillis ?: 0
        val allowance = input.rules?.dailyAllowanceSeconds?.takeIf { it in 0..86_400 } ?: 0
        val remaining = (allowance * 1_000 - min(allowance * 1_000, used) + 999) / 1_000
        return AssistedResult(AssistedDecision.ALLOW, status, checkpoint, used, remaining, reason)
    }

    private fun withinSchedule(schedules: List<AssistedSchedule>, now: Calendar): Boolean {
        if (schedules.isEmpty()) return true
        val day = (now.get(Calendar.DAY_OF_WEEK) + 5) % 7 + 1
        val previousDay = if (day == 1) 7 else day - 1
        val minute = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        return schedules.any {
            if (it.startMinute < it.endMinute) {
                day in it.daysOfWeek && minute >= it.startMinute && minute < it.endMinute
            } else {
                (day in it.daysOfWeek && minute >= it.startMinute) ||
                    (previousDay in it.daysOfWeek && minute < it.endMinute)
            }
        }
    }

    private fun calendar(wallMillis: Long, timezone: TimeZone): Calendar =
        GregorianCalendar(timezone, Locale.ROOT).apply { timeInMillis = wallMillis }

    private fun dayKey(calendar: Calendar): String = String.format(Locale.ROOT, "%04d-%02d-%02d",
        calendar.get(Calendar.YEAR), calendar.get(Calendar.MONTH) + 1, calendar.get(Calendar.DAY_OF_MONTH))

    companion object {
        private const val CLOCK_TOLERANCE_MILLIS = 2_000L
        private const val MAX_OBSERVATION_GAP_MILLIS = 15_000L
        private val availableTimezones = TimeZone.getAvailableIDs().toSet()
    }
}
