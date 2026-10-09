package com.aimanager.policy;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.CapabilityView;
import com.aimanager.fleet.Device;
import com.aimanager.schedule.ScheduleEntry;
import java.util.List;

/** Immutable resolved inputs. PREVIEW status never supplies a device's effective policy version. */
public record PolicySnapshot(int schemaVersion, String name, List<PolicyRule> sourceRules,
                             List<ApplicationDefinition> applications, List<ScheduleEntry> schedules,
                             List<String> protectedPackageExemptions, List<Target> targets) {
    public record Target(String deviceId, String registrationId, Device.Platform platform, Device.State state,
                         String managementMode, String osVersion, long deviceVersion, String observationStatus,
                         List<CapabilityView> capabilities, List<RuleEvaluation> rules) {}
    public record RuleEvaluation(List<String> sourceRuleIds, PolicyRule.Kind kind, String applicationId,
                                 String scheduleId, String permission, String domain, Long seconds, boolean required,
                                 PolicyRule.Effect predictedEffect, PolicyRule.Effect effectiveEffect,
                                 String status, String reasonCode, List<String> warnings) {}
}
