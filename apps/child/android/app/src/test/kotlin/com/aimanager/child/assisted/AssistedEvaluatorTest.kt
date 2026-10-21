package com.aimanager.child.assisted

import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AssistedEvaluatorTest {
    private val evaluator = AssistedEvaluator()
    private val game = "example.game"
    private val secondGame = "example.othergame"
    private val home = "example.launcher"
    private val wall = Instant.parse("2026-10-15T10:00:00Z").toEpochMilli()

    private fun input(
        allowance: Long = 60,
        at: Long = wall,
        schedules: List<AssistedSchedule> = emptyList(),
        timezone: String = "UTC",
    ) = AssistedInput(
        rules = AssistedRules("policy", 1, allowance, timezone, setOf(game, secondGame),
            schedules, at + 86_400_000),
        checkpoint = null,
        observedPackage = game,
        wallMillis = at,
        elapsedMillis = 100_000,
        bootCount = 4,
        permissionsGranted = true,
        enabled = true,
        configurationValid = true,
        safePackages = setOf(home),
    )

    private fun next(input: AssistedInput, result: AssistedResult, millis: Long = 1_000) =
        input.copy(checkpoint = result.checkpoint, wallMillis = input.wallMillis + millis,
            elapsedMillis = input.elapsedMillis + millis)

    @Test fun firstObservationEstablishesCheckpointWithoutRestricting() {
        val result = evaluator.update(input(allowance = 0))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.INITIALIZING, result.status)
        assertEquals("2026-10-15", result.checkpoint!!.dayKey)
        assertTrue(result.checkpoint!!.trusted)
        assertEquals(0L, result.usedMillis)
    }

    @Test fun previousForegroundIsChargedBeforeSwitchingToSafePackage() {
        val first = input()
        val second = next(first, evaluator.update(first), 3_000).copy(observedPackage = home)
        val result = evaluator.update(second)
        assertEquals(3_000L, result.usedMillis)
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(null, result.checkpoint!!.foregroundPackage)
    }

    @Test fun persistedCheckpointResumesUsageAfterProcessRestart() {
        val first = input(allowance = 2)
        val saved = evaluator.update(first).checkpoint!!.copy()
        val result = AssistedEvaluator().update(first.copy(checkpoint = saved,
            wallMillis = wall + 2_000, elapsedMillis = 102_000))
        assertEquals(2_000L, result.usedMillis)
        assertEquals(AssistedDecision.RESTRICT, result.decision)
        assertEquals("quota_exhausted", result.reason)
    }

    @Test fun multipleTargetPackagesShareOneDeviceAllowance() {
        val first = input(allowance = 3)
        val second = next(first, evaluator.update(first), 2_000).copy(observedPackage = secondGame)
        val third = next(second, evaluator.update(second), 1_000)
        val result = evaluator.update(third)
        assertEquals(3_000L, result.usedMillis)
        assertEquals(AssistedDecision.RESTRICT, result.decision)
    }

    @Test fun unmanagedPackageTimeDoesNotConsumeTargetAllowance() {
        val first = input(allowance = 1).copy(observedPackage = "example.reader")
        val second = next(first, evaluator.update(first), 3_000).copy(observedPackage = game)
        val result = evaluator.update(second)
        assertEquals(0L, result.usedMillis)
        assertEquals(AssistedDecision.ALLOW, result.decision)
    }

    @Test fun safePackagesRemainAllowedEvenWhenIncludedInTargets() {
        val first = input(allowance = 0).let {
            it.copy(rules = it.rules!!.copy(lockedPackages = setOf(home)), observedPackage = home)
        }
        val result = evaluator.update(next(first, evaluator.update(first), 3_000))
        assertEquals(0L, result.usedMillis)
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals("package_safe", result.reason)
    }

    @Test fun fractionalSecondsAccumulateWithoutRoundingAwayUsage() {
        var observation = input(allowance = 1)
        var result = evaluator.update(observation)
        repeat(4) {
            observation = next(observation, result, 250)
            result = evaluator.update(observation)
        }
        assertEquals(1_000L, result.usedMillis)
        assertEquals(0L, result.remainingSeconds)
        assertEquals(AssistedDecision.RESTRICT, result.decision)
    }

    @Test fun regularScheduleIncludesStartAndExcludesEnd() {
        val cases = listOf(
            "2026-10-19T09:00:00Z" to AssistedDecision.ALLOW,
            "2026-10-19T16:59:58Z" to AssistedDecision.ALLOW,
            "2026-10-19T17:00:00Z" to AssistedDecision.RESTRICT,
            "2026-10-18T10:00:00Z" to AssistedDecision.RESTRICT,
        )
        for ((time, expected) in cases) {
            val first = input(at = Instant.parse(time).toEpochMilli(),
                schedules = listOf(AssistedSchedule(setOf(1), 9 * 60, 17 * 60)))
            assertEquals(time, expected, evaluator.update(next(first, evaluator.update(first))).decision)
        }
    }

    @Test fun overnightScheduleUsesPreviousStartDayAfterMidnight() {
        val cases = listOf(
            "2026-10-19T21:30:00Z" to AssistedDecision.ALLOW,
            "2026-10-20T02:00:00Z" to AssistedDecision.ALLOW,
            "2026-10-20T06:00:00Z" to AssistedDecision.RESTRICT,
            "2026-10-21T02:00:00Z" to AssistedDecision.RESTRICT,
        )
        for ((time, expected) in cases) {
            val first = input(at = Instant.parse(time).toEpochMilli(),
                schedules = listOf(AssistedSchedule(setOf(1), 21 * 60 + 30, 6 * 60)))
            assertEquals(time, expected, evaluator.update(next(first, evaluator.update(first))).decision)
        }
    }

    @Test fun temporaryExceptionExpiresAtExactBoundaryAndStillMetersUsage() {
        val first = input(allowance = 0).let {
            it.copy(rules = it.rules!!.copy(exceptionUntilEpochMillis = wall + 3_000))
        }
        val second = next(first, evaluator.update(first), 2_000)
        val allowed = evaluator.update(second)
        assertEquals(AssistedDecision.ALLOW, allowed.decision)
        assertEquals("exception_active", allowed.reason)
        assertEquals(2_000L, allowed.usedMillis)
        val expired = evaluator.update(next(second, allowed))
        assertEquals(AssistedDecision.RESTRICT, expired.decision)
        assertEquals(3_000L, expired.usedMillis)
    }

    @Test fun expiredConfigurationFailsOpenAtExactBoundary() {
        val first = input(allowance = 0).let {
            it.copy(rules = it.rules!!.copy(validUntilEpochMillis = wall + 1_000))
        }
        val result = evaluator.update(next(first, evaluator.update(first)))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.EXPIRED, result.status)
    }

    @Test fun disabledRuntimeFailsOpen() {
        val first = input(allowance = 0)
        val result = evaluator.update(next(first, evaluator.update(first)).copy(enabled = false))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.DISABLED, result.status)
        assertEquals(null, result.checkpoint!!.foregroundPackage)
    }

    @Test fun missingPermissionFailsOpenAndStopsFutureMetering() {
        val first = input(allowance = 0)
        val second = next(first, evaluator.update(first)).copy(permissionsGranted = false)
        val unavailable = evaluator.update(second)
        assertEquals(AssistedDecision.ALLOW, unavailable.decision)
        assertEquals(AssistedStatus.PERMISSION_MISSING, unavailable.status)
        val restored = evaluator.update(next(second, unavailable).copy(permissionsGranted = true))
        assertEquals(1_000L, restored.usedMillis)
    }

    @Test fun unverifiedConfigurationFailsOpen() {
        val result = evaluator.update(input(allowance = 0).copy(configurationValid = false))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CONFIGURATION_INVALID, result.status)
    }

    @Test fun absentConfigurationFailsOpen() {
        val result = evaluator.update(input(allowance = 0).copy(rules = null))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CONFIGURATION_INVALID, result.status)
    }

    @Test fun malformedRulesCannotRestrict() {
        val first = input(allowance = 0)
        val rules = first.rules!!
        val malformed = listOf(
            rules.copy(timezoneId = "Missing/Zone"),
            rules.copy(dailyAllowanceSeconds = -1),
            rules.copy(policyId = " "),
            rules.copy(policyVersion = -1),
            rules.copy(schedules = listOf(AssistedSchedule(setOf(8), 0, 60))),
            rules.copy(schedules = listOf(AssistedSchedule(emptySet(), 0, 60))),
            rules.copy(schedules = listOf(AssistedSchedule(setOf(1), -1, 60))),
            rules.copy(schedules = listOf(AssistedSchedule(setOf(1), 60, 60))),
            rules.copy(lockedPackages = setOf("")),
        )
        for (invalid in malformed) {
            val result = evaluator.update(first.copy(rules = invalid))
            assertEquals(invalid.toString(), AssistedDecision.ALLOW, result.decision)
            assertEquals(invalid.toString(), AssistedStatus.CONFIGURATION_INVALID, result.status)
        }
    }

    @Test fun midnightResetsDailyUsageAndChargesOnlyNewDayPortion() {
        val first = input(at = Instant.parse("2026-10-15T15:59:58Z").toEpochMilli(), timezone = "Asia/Shanghai")
        val saved = evaluator.update(first).checkpoint!!.copy(usedMillis = 45_000)
        val result = evaluator.update(first.copy(checkpoint = saved,
            wallMillis = first.wallMillis + 4_000, elapsedMillis = 104_000))
        assertEquals("2026-10-16", result.checkpoint!!.dayKey)
        assertEquals(2_000L, result.usedMillis)
    }

    @Test fun newerRuleVersionPreservesTodaysUsage() {
        val first = input()
        val second = next(first, evaluator.update(first), 5_000)
        val used = evaluator.update(second)
        val refreshed = next(second, used).let {
            it.copy(rules = it.rules!!.copy(policyVersion = 2, dailyAllowanceSeconds = 4))
        }
        val result = evaluator.update(refreshed)
        assertEquals(6_000L, result.usedMillis)
        assertEquals(AssistedStatus.INITIALIZING, result.status)
        assertEquals(AssistedDecision.ALLOW, result.decision)
        val active = evaluator.update(next(refreshed, result))
        assertEquals(7_000L, active.usedMillis)
        assertEquals(AssistedDecision.RESTRICT, active.decision)
    }

    @Test fun staleRuleVersionCannotResetUsageOrTrust() {
        val first = input(allowance = 0).let { it.copy(rules = it.rules!!.copy(policyVersion = 2)) }
        val second = next(first, evaluator.update(first)).let {
            it.copy(rules = it.rules!!.copy(policyVersion = 1))
        }
        val result = evaluator.update(second)
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CONFIGURATION_INVALID, result.status)
        assertEquals(2L, result.checkpoint!!.policyVersion)
    }

    @Test fun wallClockRollbackFailsOpenWithoutResettingUsage() {
        val first = input(allowance = 0)
        val saved = evaluator.update(first).checkpoint!!.copy(usedMillis = 10_000)
        val result = evaluator.update(first.copy(checkpoint = saved,
            wallMillis = wall - 1_000, elapsedMillis = 101_000))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CLOCK_ANOMALY, result.status)
        assertFalse(result.checkpoint!!.trusted)
        assertEquals(10_000L, result.usedMillis)
    }

    @Test fun forwardWallClockJumpFailsOpen() {
        val first = input(allowance = 0)
        val result = evaluator.update(first.copy(checkpoint = evaluator.update(first).checkpoint,
            wallMillis = wall + 3_600_000, elapsedMillis = 101_000))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CLOCK_ANOMALY, result.status)
    }

    @Test fun cumulativeSmallClockChangesFailOpenAcrossPersistedCheckpoints() {
        var observation = input(allowance = 0)
        var result = evaluator.update(observation)
        repeat(3) {
            observation = observation.copy(checkpoint = result.checkpoint!!.copy(),
                wallMillis = observation.wallMillis + 2_000,
                elapsedMillis = observation.elapsedMillis + 1_000)
            result = AssistedEvaluator().update(observation)
        }
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CLOCK_ANOMALY, result.status)
        assertEquals(2_000L, result.usedMillis)
    }

    @Test fun rebootFailsOpen() {
        val first = input(allowance = 0)
        val result = evaluator.update(first.copy(checkpoint = evaluator.update(first).checkpoint,
            wallMillis = wall + 1_000, elapsedMillis = 1_000, bootCount = 5))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CLOCK_ANOMALY, result.status)
    }

    @Test fun decreasingElapsedTimeFailsOpen() {
        val first = input(allowance = 0)
        val result = evaluator.update(first.copy(checkpoint = evaluator.update(first).checkpoint,
            wallMillis = wall + 1_000, elapsedMillis = 99_000))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CLOCK_ANOMALY, result.status)
    }

    @Test fun missedObservationPeriodFailsOpenInsteadOfChargingOldForeground() {
        val first = input(allowance = 0)
        val result = evaluator.update(next(first, evaluator.update(first), 16_000))
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.CLOCK_ANOMALY, result.status)
        assertEquals(0L, result.usedMillis)
    }

    @Test fun anomalyRequiresNewerConfigurationBeforeRestrictionsResume() {
        val first = input(allowance = 0)
        val second = next(first, evaluator.update(first), 16_000)
        val anomaly = evaluator.update(second)
        val third = next(second, anomaly)
        val stillUnsafe = evaluator.update(third)
        assertEquals(AssistedStatus.CLOCK_ANOMALY, stillUnsafe.status)
        assertEquals(AssistedDecision.ALLOW, stillUnsafe.decision)
        val refreshed = next(third, stillUnsafe).let { it.copy(rules = it.rules!!.copy(policyVersion = 2)) }
        val restored = evaluator.update(refreshed)
        assertEquals(AssistedStatus.INITIALIZING, restored.status)
        assertTrue(restored.checkpoint!!.trusted)
        assertEquals(AssistedDecision.RESTRICT, evaluator.update(next(refreshed, restored)).decision)
    }

    @Test fun corruptCheckpointFailsOpen() {
        val first = input(allowance = 0)
        val saved = evaluator.update(first).checkpoint!!
        for (invalid in listOf(saved.copy(usedMillis = -1), saved.copy(dayKey = "1900-01-01"))) {
            val result = evaluator.update(first.copy(checkpoint = invalid,
                wallMillis = wall + 1_000, elapsedMillis = 101_000))
            assertEquals(AssistedDecision.ALLOW, result.decision)
            assertEquals(AssistedStatus.CLOCK_ANOMALY, result.status)
        }
    }

    @Test fun absentForegroundClosesKnownIntervalAndStopsMetering() {
        val first = input(allowance = 0)
        val second = next(first, evaluator.update(first)).copy(observedPackage = null)
        val result = evaluator.update(second)
        assertEquals(AssistedDecision.ALLOW, result.decision)
        assertEquals(AssistedStatus.FOREGROUND_UNAVAILABLE, result.status)
        assertEquals(1_000L, result.usedMillis)
        assertEquals(null, result.checkpoint!!.foregroundPackage)
        assertEquals(1_000L, evaluator.update(next(second, result)).usedMillis)
    }

    @Test fun validCachedRulesWorkWithoutNetworkInput() {
        val first = input(allowance = 0)
        val result = evaluator.update(next(first, evaluator.update(first)))
        assertNotNull(result.checkpoint)
        assertEquals(AssistedStatus.ACTIVE, result.status)
        assertEquals(AssistedDecision.RESTRICT, result.decision)
    }
}
