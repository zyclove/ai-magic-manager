package com.aimanager.delivery;
import java.util.List;
public record FamilyAssistanceDocument(int schemaVersion,String mode,boolean enabled,int dailyAllowanceSeconds,
    String timeZoneId,List<String> meteredPackages,List<Window> allowedWindows,long validUntil,Long exceptionUntil){
  public record Window(List<Integer> daysOfWeek,int startMinute,int endMinute){}
}
