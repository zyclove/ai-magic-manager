package com.aimanager.delivery;

import com.aimanager.catalog.ApplicationDefinition;
import com.aimanager.policy.PolicySnapshot;
import com.aimanager.schedule.ScheduleEntry;
import java.util.List;

/** Device-scoped display/configuration document. It does not contain other devices or administrator details. */
public record ConfigurationDocument(String name, List<PolicySnapshot.RuleEvaluation> rules,
                                    List<ApplicationDefinition> applications, List<ScheduleEntry> schedules,
                                    List<String> protectedPackageExemptions,
                                    @com.fasterxml.jackson.annotation.JsonInclude(com.fasterxml.jackson.annotation.JsonInclude.Include.NON_NULL)
                                    FamilyAssistanceDocument familyAssistance) {
  public ConfigurationDocument(String name,List<PolicySnapshot.RuleEvaluation> rules,List<ApplicationDefinition> applications,
      List<ScheduleEntry> schedules,List<String> exemptions){this(name,rules,applications,schedules,exemptions,null);}
}
