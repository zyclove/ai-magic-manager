package com.aimanager.policy.internal;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.fleet.*;
import com.aimanager.policy.*;
import com.aimanager.shared.DomainException;
import java.net.IDN;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import static com.aimanager.policy.PolicyRule.Kind.*;
import static com.aimanager.policy.PolicyRule.Effect.*;

/** Declarative validation and conflict explanation; actual OS execution belongs to certified adapters. */
@Component
class RuleCompiler {
    private static final Set<String> RUNTIME = Set.of("CAMERA", "RECORD_AUDIO", "READ_CONTACTS", "WRITE_CONTACTS", "GET_ACCOUNTS",
        "READ_CALENDAR", "WRITE_CALENDAR", "ACCESS_COARSE_LOCATION", "ACCESS_FINE_LOCATION", "ACCESS_BACKGROUND_LOCATION",
        "POST_NOTIFICATIONS", "READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_MEDIA_AUDIO", "READ_MEDIA_VISUAL_USER_SELECTED",
        "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE", "BLUETOOTH_SCAN", "BLUETOOTH_CONNECT", "BLUETOOTH_ADVERTISE",
        "NEARBY_WIFI_DEVICES", "BODY_SENSORS", "BODY_SENSORS_BACKGROUND", "READ_PHONE_STATE", "READ_PHONE_NUMBERS", "CALL_PHONE",
        "ANSWER_PHONE_CALLS", "ADD_VOICEMAIL", "USE_SIP", "PROCESS_OUTGOING_CALLS", "ACTIVITY_RECOGNITION", "READ_SMS", "SEND_SMS",
        "RECEIVE_SMS", "RECEIVE_MMS", "RECEIVE_WAP_PUSH", "READ_CALL_LOG", "WRITE_CALL_LOG", "UWB_RANGING");
    private static final Set<String> SPECIAL = Set.of("USAGE_ACCESS", "OVERLAY", "NOTIFICATION_ACCESS", "ACCESSIBILITY", "VPN");
    private static final Set<String> BASELINE = Set.of("com.android.settings", "com.android.dialer", "com.google.android.dialer",
        "com.aimanager.device", "com.aimanager.guardian");
    private final Set<String> protectedPackages;
    RuleCompiler(@Value("${manager.policies.additional-protected-packages:}") String configured) {
        var packages = new HashSet<>(BASELINE);
        Arrays.stream(configured.split(",")).map(String::strip).filter(p -> !p.isEmpty())
            .map(p -> p.toLowerCase(Locale.ROOT)).forEach(packages::add);
        this.protectedPackages = Set.copyOf(packages);
    }

    void validate(List<PolicyRule> rules, Map<String, ApplicationDefinition> apps) {
        if (rules.stream().map(PolicyRule::id).distinct().count() != rules.size()) throw DomainException.invalid("DUPLICATE_RULE_ID");
        for (var rule : rules) {
            var used = new HashSet<String>();
            Set<PolicyRule.Effect> effects;
            switch (rule.kind()) {
                case APP_LAUNCH, APP_INSTALL -> { required(rule.applicationId()); used.add("applicationId"); effects = Set.of(ALLOW, DENY); }
                case APP_UNINSTALL -> { required(rule.applicationId()); used.add("applicationId"); effects = Set.of(ALLOW, PROTECT); }
                case RUNTIME_PERMISSION, SPECIAL_ACCESS -> {
                    required(rule.applicationId()); required(rule.permission()); used.addAll(Set.of("applicationId", "permission"));
                    effects = Set.of(GRANT, DENY, DEFAULT);
                    if (rule.kind() == RUNTIME_PERMISSION && (!rule.permission().startsWith("android.permission.")
                        || !RUNTIME.contains(rule.permission().substring("android.permission.".length()))))
                        throw DomainException.invalid("NOT_RUNTIME_PERMISSION");
                    if (rule.kind() == SPECIAL_ACCESS && !SPECIAL.contains(rule.permission())) throw DomainException.invalid("INVALID_SPECIAL_ACCESS");
                }
                case DAILY_QUOTA, USAGE_REMINDER -> {
                    if (rule.seconds() == null) throw DomainException.invalid("RULE_FIELD_REQUIRED");
                    used.addAll(Set.of("applicationId", "seconds")); effects = Set.of(rule.kind() == DAILY_QUOTA ? LIMIT : REMIND);
                }
                case TIME_WINDOW -> { required(rule.scheduleId()); used.addAll(Set.of("applicationId", "scheduleId")); effects = Set.of(ALLOW); }
                case DOMAIN_ACCESS -> {
                    required(rule.domain()); used.add("domain"); effects = Set.of(ALLOW, DENY);
                    if (!canonicalDomain(rule.domain()).equals(rule.domain())) throw DomainException.invalid("DOMAIN_NOT_CANONICAL");
                }
                default -> throw DomainException.invalid("INVALID_RULE_KIND");
            }
            if (!effects.contains(rule.effect())) throw DomainException.invalid("INVALID_RULE_EFFECT");
            var fields = new HashMap<String, Object>();
            fields.put("applicationId", rule.applicationId()); fields.put("scheduleId", rule.scheduleId());
            fields.put("seconds", rule.seconds()); fields.put("permission", rule.permission()); fields.put("domain", rule.domain());
            if (fields.entrySet().stream().anyMatch(e -> e.getValue() != null && !used.contains(e.getKey())))
                throw DomainException.invalid("UNUSED_RULE_FIELD");
            if (rule.applicationId() != null) {
                var app = apps.get(rule.applicationId());
                if (protectedPackages.contains(app.packageName().toLowerCase(Locale.ROOT)) && restrictsSafety(rule))
                    throw new DomainException(HttpStatus.UNPROCESSABLE_ENTITY, "SAFETY_BASELINE_PROTECTED");
            }
        }
    }
    private boolean restrictsSafety(PolicyRule r) {
        return switch (r.kind()) {
            case APP_LAUNCH, APP_INSTALL, RUNTIME_PERMISSION, SPECIAL_ACCESS -> r.effect() == DENY;
            case DAILY_QUOTA, TIME_WINDOW -> true;
            case APP_UNINSTALL -> r.effect() == ALLOW;
            default -> false;
        };
    }
    List<String> protectedPackageExemptions() { return protectedPackages.stream().sorted().toList(); }
    private void required(String value) { if (value == null || value.isBlank()) throw DomainException.invalid("RULE_FIELD_REQUIRED"); }
    private String canonicalDomain(String value) {
        try {
            String domain = IDN.toASCII(value, IDN.USE_STD3_ASCII_RULES).toLowerCase(Locale.ROOT);
            if (domain.length() > 253 || !domain.contains(".") || domain.endsWith(".") || domain.matches("[0-9.]+")
                || Arrays.stream(domain.split("\\.", -1)).anyMatch(label -> label.isEmpty() || label.length() > 63))
                throw DomainException.invalid("INVALID_DOMAIN");
            return domain;
        } catch (IllegalArgumentException failure) { throw DomainException.invalid("INVALID_DOMAIN"); }
    }

    List<PolicySnapshot.RuleEvaluation> compile(List<PolicyRule> rules, Map<String, ApplicationDefinition> apps, FleetPolicyAccess.Target target) {
        var groups = new TreeMap<String, List<PolicyRule>>();
        for (var rule : rules) {
            // Two distinct time-window constraints remain intersections rather than collapsing to one allow rule.
            String key = rule.kind() + "|" + rule.applicationId() + "|" + rule.scheduleId() + "|" + rule.permission() + "|" + rule.domain();
            groups.computeIfAbsent(key, ignored -> new ArrayList<>()).add(rule);
        }
        var result = new ArrayList<PolicySnapshot.RuleEvaluation>();
        for (var group : groups.values()) {
            group.sort(Comparator.comparing(PolicyRule::id));
            var first = group.get(0);
            var effects = group.stream().map(PolicyRule::effect).collect(java.util.stream.Collectors.toSet());
            var predicted = effects.contains(DENY) ? DENY : effects.contains(PROTECT) ? PROTECT : effects.contains(GRANT) ? GRANT : first.effect();
            // DEFAULT must not silently become GRANT; same-layer runtime conflicts choose the less privileged value.
            if ((first.kind() == RUNTIME_PERMISSION || first.kind() == SPECIAL_ACCESS) && effects.contains(DEFAULT) && !effects.contains(DENY)) predicted = DEFAULT;
            Long seconds = group.stream().map(PolicyRule::seconds).filter(Objects::nonNull).min(Long::compare).orElse(null);
            String capability = switch (first.kind()) {
                case APP_LAUNCH -> "app.launch_block";
                case APP_INSTALL -> "app.install_policy";
                case APP_UNINSTALL -> "managed.app_policy";
                case RUNTIME_PERMISSION -> "permission.runtime";
                case SPECIAL_ACCESS -> "permission.special_access";
                case DAILY_QUOTA -> "usage.shared_quota_enforced";
                case TIME_WINDOW -> "usage.schedule_enforced";
                case DOMAIN_ACCESS -> "network.domain_filter";
                case USAGE_REMINDER -> "usage.reminder";
            };
            var evidence = target.capabilities().stream().filter(c -> c.key().equals(capability)).findFirst().orElse(null);
            String status = evidence == null ? "UNKNOWN" : evidence.status(), reason = evidence == null ? "CAPABILITY_NOT_VERIFIED" : evidence.limitationCode();
            if (evidence != null && evidence.effectiveSupported()) { status = "SUPPORTED_PENDING"; reason = "AWAITING_EXECUTION"; }
            // Capability alone does not prove a declared package/profile/signing identity matches installed software.
            if ("SUPPORTED_PENDING".equals(status) && first.applicationId() != null
                && !"INSTALLED_VERIFIED".equals(apps.get(first.applicationId()).evidenceStatus())) {
                status = "UNVERIFIED"; reason = "APPLICATION_IDENTITY_NOT_VERIFIED";
            }
            if (target.device().state() != Device.State.ACTIVE) { status = "UNAVAILABLE"; reason = "DEVICE_NOT_ACTIVE"; }
            if (first.applicationId() != null && apps.get(first.applicationId()).platform() != target.device().platform()) {
                status = "UNSUPPORTED"; reason = "APPLICATION_PLATFORM_MISMATCH";
            }
            if (first.applicationId() != null && apps.get(first.applicationId()).profile() != ApplicationDefinition.Profile.PRIMARY) {
                status = "UNSUPPORTED"; reason = "APPLICATION_PROFILE_NOT_VERIFIED";
            }
            var warnings = new ArrayList<String>();
            if (effects.size() > 1) warnings.add("SAME_LAYER_CONFLICT_RESTRICTIVE_WINS");
            if (first.kind() == DAILY_QUOTA && group.stream().map(PolicyRule::seconds).distinct().count() > 1) warnings.add("SMALLER_QUOTA_WINS");
            if (first.kind() == APP_INSTALL && predicted == DENY) warnings.add("INSTALL_DENY_MAY_REMOVE_EXISTING_APP");
            if (first.kind() == SPECIAL_ACCESS && predicted == GRANT) warnings.add("SYSTEM_USER_ACTION_REQUIRED");
            result.add(new PolicySnapshot.RuleEvaluation(group.stream().map(PolicyRule::id).toList(), first.kind(), first.applicationId(),
                first.scheduleId(), first.permission(), first.domain(), seconds, group.stream().anyMatch(PolicyRule::required), predicted, null,
                status, reason, List.copyOf(warnings)));
        }
        return List.copyOf(result);
    }
}
