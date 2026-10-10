package com.aimanager.support.internal;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import java.sql.*;
import java.time.Clock;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

@Component
class SupportGrantStore {
  final JdbcTemplate db;
  private final Clock clock;

  SupportGrantStore(JdbcTemplate db, Clock clock) {
    this.db = db;
    this.clock = clock;
  }

  void head(String tenant) {
    db.update(
        "INSERT INTO support_grant_heads(tenant_id) VALUES(?) ON DUPLICATE KEY UPDATE"
            + " tenant_id=tenant_id",
        tenant);
  }

  Row customer(String tenant, String id, boolean lock) {
    var rows =
        db.query(
            "SELECT * FROM support_grants WHERE tenant_id=? AND id=?" + (lock ? " FOR UPDATE" : ""),
            this::map,
            tenant,
            id);
    if (rows.size() != 1) throw DomainException.denied();
    return rows.get(0);
  }

  Row recipient(String id, String actor, boolean lock) {
    var rows =
        db.query(
            "SELECT * FROM support_grants WHERE id=? AND recipient_key=?"
                + (lock ? " FOR UPDATE" : ""),
            this::map,
            id,
            ActorKeys.key(actor));
    if (rows.size() != 1 || !rows.get(0).recipientActorId().equals(actor))
      throw DomainException.denied();
    return rows.get(0);
  }

  Row map(ResultSet r, int index) throws SQLException {
    return new Row(
        r.getString("id"),
        r.getString("tenant_id"),
        r.getString("device_id"),
        r.getString("subject_id"),
        r.getString("registration_id"),
        r.getString("creator_actor_id"),
        r.getLong("creator_member_version"),
        r.getString("recipient_actor_id"),
        r.getString("recipient_display_name"),
        r.getString("recipient_verified_email"),
        r.getInt("type_mask"),
        r.getString("state"),
        r.getLong("version"),
        r.getLong("created_at"),
        r.getLong("expires_at"));
  }

  Grant view(Row row) {
    String state =
        row.state().equals("ACTIVE") && row.expiresAt() <= clock.millis() ? "EXPIRED" : row.state();
    return new Grant(
        row.id(),
        row.tenantId(),
        row.deviceId(),
        row.registrationId(),
        row.creatorActorId(),
        row.recipientActorId(),
        row.displayName(),
        row.verifiedEmail(),
        SupportGrantTypes.list(row.typeMask()),
        state,
        row.version(),
        row.createdAt(),
        row.expiresAt());
  }

  record Row(
      String id,
      String tenantId,
      String deviceId,
      String subjectId,
      String registrationId,
      String creatorActorId,
      long creatorMemberVersion,
      String recipientActorId,
      String displayName,
      String verifiedEmail,
      int typeMask,
      String state,
      long version,
      long createdAt,
      long expiresAt) {}

  record Grant(
      String id,
      String tenantId,
      String deviceId,
      String registrationId,
      String creatorActorId,
      String recipientActorId,
      String recipientDisplayName,
      String recipientVerifiedEmail,
      java.util.List<String> diagnosticTypes,
      String state,
      long version,
      long createdAt,
      long expiresAt) {}

  record Reference(String id) {}
}
