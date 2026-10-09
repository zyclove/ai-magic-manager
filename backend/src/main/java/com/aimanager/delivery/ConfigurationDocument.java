package com.aimanager.delivery;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.policy.PolicySnapshot;
import com.aimanager.schedule.ScheduleEntry;
import java.util.List;

/** Device-scoped display/configuration document. It does not contain other devices or administrator details. */
public record ConfigurationDocument(String name, List<PolicySnapshot.RuleEvaluation> rules,
                                    List<ApplicationDefinition> applications, List<ScheduleEntry> schedules,
                                    List<String> protectedPackageExemptions) {}
