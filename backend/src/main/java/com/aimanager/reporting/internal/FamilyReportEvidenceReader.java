package com.aimanager.reporting.internal;
import com.aimanager.reporting.FamilyReportEvidence;
import com.aimanager.tenant.TenantAccess;
import java.time.*;
import java.util.*;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Reuses report authorization and coverage; no names, phone numbers or raw events sent to AI. */
@Service
class FamilyReportEvidenceReader implements FamilyReportEvidence {
  private final TenantAccess authority;private final UsageReportService reports;private final Clock clock;
  FamilyReportEvidenceReader(TenantAccess authority,UsageReportService reports,Clock clock){this.authority=authority;this.reports=reports;this.clock=clock;}
  @Transactional(timeout=10)
  public Map<String,Object> read(String tenant,String actor,String subject,String device){
    authority.requireRole(tenant,actor,TenantAccess.Role.OWNER,TenantAccess.Role.GUARDIAN);
    ZoneId zone=ZoneId.of("Asia/Shanghai");var end=LocalDate.now(clock.withZone(zone)).atStartOfDay(zone);
    var report=reports.query(tenant,actor,List.of(device),end.minusDays(7).toInstant().toEpochMilli(),end.toInstant().toEpochMilli(),zone.getId(),"DAY",new UsageReportScope.Selection("SUBJECT",subject,null));
    var selected=report.devices().get(0);
    var apps=new ArrayList<Map<String,Object>>();
    for(var app:selected.applications().stream().limit(30).toList()){
      var buckets=new ArrayList<Map<String,Object>>();
      for(var bucket:app.buckets()){
        var item=new LinkedHashMap<String,Object>();item.put("from",bucket.start());item.put("to",bucket.end());item.put("lowerMillis",bucket.lowerMillis());item.put("upperMillis",bucket.upperMillis());buckets.add(item);
      }
      apps.add(Map.of("applicationReference",app.packageName(),"days",buckets));
    }
    return Map.of("status",selected.status(),"from",report.from(),"to",report.to(),"coverageMillis",selected.queryCoverageMillis(),"windowMillis",report.to()-report.from(),"evidenceStatus",report.evidenceStatus(),"applications",apps);
  }
}
