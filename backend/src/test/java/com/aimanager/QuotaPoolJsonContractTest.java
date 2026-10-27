package com.aimanager;

import static org.assertj.core.api.Assertions.assertThat;

import com.aimanager.quota.QuotaPool;
import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Instant;
import java.util.HashSet;
import java.util.List;
import org.junit.jupiter.api.Test;

class QuotaPoolJsonContractTest {
  @Test void allLedgerFactsRemainExplicitWhenGlobalSerializationOmitsNulls() {
    var json = new ObjectMapper().setSerializationInclusion(JsonInclude.Include.NON_NULL);
    long start = Instant.parse("2026-10-27T00:00:00Z").toEpochMilli();
    String subject = "b1111111-1111-4111-8111-111111111111";
    String application = "c1111111-1111-4111-8111-111111111111";
    String plan = "d1111111-1111-4111-8111-111111111111";
    var manual = new QuotaPool("a1111111-1111-4111-8111-111111111111", subject,
        "每日总额度", QuotaPool.Scope.TOTAL, null, "2026-10-27", "UTC",
        start, start + 86_400_000L, 3600, 0, 0, 3600, "CONFIGURED", "LEDGER_ONLY", 0,
        null, null);
    var planned = new QuotaPool("a2222222-2222-4222-8222-222222222222", subject,
        "应用计划额度", QuotaPool.Scope.APPLICATION, application, "2026-10-27", "UTC",
        start, start + 86_400_000L, 7200, 95, 5, 7100, "CONFIGURED", "LEDGER_ONLY", 3,
        plan, 2L);
    for (var pool : List.of(manual, planned)) {
      JsonNode result = json.valueToTree(pool);
      var fields = new HashSet<String>();
      result.fieldNames().forEachRemaining(fields::add);
      assertThat(fields).containsExactlyInAnyOrder(
          "id", "subjectId", "name", "scope", "applicationId", "periodId", "timeZone",
          "periodStart", "periodEnd", "limitSeconds", "usedSeconds", "reservedSeconds",
          "availableSeconds", "status", "evidenceStatus", "version", "planId", "planVersion");
      assertThat(result.size()).isEqualTo(18);
      assertThat(result.path("id").asText()).isEqualTo(pool.id());
      assertThat(result.path("scope").asText()).isEqualTo(pool.scope().name());
      assertThat(result.path("limitSeconds").asLong()).isEqualTo(pool.limitSeconds());
      if (pool == manual) {
        assertThat(result.get("applicationId").isNull()).isTrue();
        assertThat(result.get("planId").isNull()).isTrue();
        assertThat(result.get("planVersion").isNull()).isTrue();
      } else {
        assertThat(result.path("applicationId").asText()).isEqualTo(application);
        assertThat(result.path("planId").asText()).isEqualTo(plan);
        assertThat(result.path("planVersion").asLong()).isEqualTo(2);
      }
    }
  }
}
