package com.aimanager.tenant.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditSelection;
import com.aimanager.audit.AuditService;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.tenant.TenantAccess;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.*;

/** A separate read contract keeps legacy ID pagination compatible. Cursors never grant access. */
@RestController
@RequestMapping("/api/v1/tenants/{tenantId}/audit-events")
public class AuditExplorer {
  private final JdbcTemplate jdbc;
  private final TenantAccess access;
  private static final RowMapper<AuditService.Event> ROW =
      (r, n) ->
          new AuditService.Event(
              r.getString("id"),
              r.getString("actor_id"),
              r.getString("action"),
              r.getString("resource_id"),
              r.getString("correlation_id"),
              r.getLong("occurred_at"));

  public AuditExplorer(JdbcTemplate jdbc, TenantAccess access) {
    this.jdbc = jdbc;
    this.access = access;
  }

  @GetMapping("/search")
  public ItemPage<AuditService.Event> search(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @RequestParam long from,
      @RequestParam long to,
      @RequestParam(defaultValue = "20") int limit,
      @RequestParam(required = false) String action,
      @RequestParam(required = false) String resourceId,
      @RequestParam(required = false) String correlationId,
      @RequestParam(required = false) String cursor) {
    access.requireRole(tenantId, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    var selection = new AuditSelection(from, to, action, resourceId, correlationId);
    if (limit < 1 || limit > 50) throw DomainException.invalid("INVALID_PAGE_SIZE");
    String scope = digest(tenantId + "|" + selection.fingerprintMaterial());
    var predicate = selection.predicate(tenantId);
    var sql = new StringBuilder("SELECT * FROM audit_events WHERE " + predicate.sql());
    var values = new ArrayList<Object>(predicate.parameters());
    if (cursor != null) {
      try {
        if (cursor.length() > 256) throw new IllegalArgumentException();
        var decoded = new String(Base64.getUrlDecoder().decode(cursor), StandardCharsets.UTF_8);
        var parts = decoded.split("\\|", -1);
        if (parts.length != 4 || !parts[0].equals("1") || !parts[1].equals(scope))
          throw new IllegalArgumentException();
        long time = Long.parseLong(parts[2]);
        uuid(parts[3]);
        if (time < from || time >= to || !encode(scope, time, parts[3]).equals(cursor))
          throw new IllegalArgumentException();
        sql.append(" AND (occurred_at<? OR (occurred_at=? AND id<?))");
        values.add(time);
        values.add(time);
        values.add(parts[3]);
      } catch (IllegalArgumentException | DomainException invalid) {
        throw DomainException.invalid("INVALID_CURSOR");
      }
    }
    sql.append(" ORDER BY occurred_at DESC,id DESC LIMIT ?");
    values.add(limit + 1);
    var rows = jdbc.query(sql.toString(), ROW, values.toArray());
    return ItemPage.from(rows, limit, e -> encode(scope, e.occurredAt(), e.id()));
  }

  @GetMapping("/{eventId}")
  public AuditService.Event detail(
      @AuthenticationPrincipal Jwt actor,
      @PathVariable String tenantId,
      @PathVariable String eventId) {
    access.requireRole(tenantId, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN, AUDITOR);
    uuid(eventId);
    return jdbc
        .query("SELECT * FROM audit_events WHERE tenant_id=? AND id=?", ROW, tenantId, eventId)
        .stream()
        .findFirst()
        .orElseThrow(() -> new DomainException(HttpStatus.NOT_FOUND, "AUDIT_EVENT_UNAVAILABLE"));
  }

  private static void uuid(String value) {
    try {
      if (!UUID.fromString(value).toString().equals(value)) throw new IllegalArgumentException();
    } catch (IllegalArgumentException invalid) {
      throw DomainException.invalid("INVALID_AUDIT_ID");
    }
  }

  private static String encode(String scope, long time, String id) {
    return Base64.getUrlEncoder()
        .withoutPadding()
        .encodeToString(("1|" + scope + "|" + time + "|" + id).getBytes(StandardCharsets.UTF_8));
  }

  private static String digest(String value) {
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException impossible) {
      throw new IllegalStateException(impossible);
    }
  }
}
