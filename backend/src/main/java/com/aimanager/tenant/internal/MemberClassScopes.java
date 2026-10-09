package com.aimanager.tenant.internal;

import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.List;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Class membership grants are tied to a specific persisted membership version. */
@Component
class MemberClassScopes {
  private final JdbcTemplate db;
  private final ObjectMapper mapper;

  MemberClassScopes(JdbcTemplate db, ObjectMapper mapper) {
    this.db = db;
    this.mapper = mapper;
  }

  List<String> normalize(List<String> input) {
    if (input == null) return List.of();
    if (input.size() > 50
        || input.stream()
            .anyMatch(
                v ->
                    v == null
                        || !v.matches(
                            "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))
        || input.stream().distinct().count() != input.size())
      throw DomainException.invalid("INVALID_CLASS_SCOPE");
    return input.stream().sorted().toList();
  }

  void validate(String tenant, List<String> ids) {
    for (String id : ids)
      if (db.queryForList(
                  "SELECT id FROM organization_classes WHERE tenant_id=? AND id=? AND archived_at"
                      + " IS NULL FOR UPDATE",
                  tenant,
                  id)
              .size()
          != 1) throw DomainException.invalid("CLASS_SCOPE_UNAVAILABLE");
  }

  void invite(String tenant, String invitation, List<String> ids) {
    for (String id : ids)
      db.update(
          "INSERT INTO invitation_class_scopes(invitation_id,tenant_id,class_id) VALUES(?,?,?)",
          invitation,
          tenant,
          id);
  }

  List<String> invitation(String tenant, String invitation) {
    return db.queryForList(
        "SELECT class_id FROM invitation_class_scopes WHERE tenant_id=? AND invitation_id=? ORDER"
            + " BY class_id",
        String.class,
        tenant,
        invitation);
  }

  void assign(String tenant, String actorKey, long version, List<String> ids) {
    db.update(
        "DELETE FROM tenant_member_class_scopes WHERE tenant_id=? AND actor_key=?",
        tenant,
        actorKey);
    for (String id : ids)
      db.update(
          "INSERT INTO tenant_member_class_scopes(tenant_id,actor_key,class_id,member_version)"
              + " VALUES(?,?,?,?)",
          tenant,
          actorKey,
          id,
          version);
  }

  List<String> assigned(String tenant, String actorKey, long version) {
    return db.queryForList(
        "SELECT class_id FROM tenant_member_class_scopes WHERE tenant_id=? AND actor_key=? AND"
            + " member_version=? ORDER BY class_id",
        String.class,
        tenant,
        actorKey,
        version);
  }

  String json(List<String> values) {
    try {
      return mapper.writeValueAsString(values);
    } catch (JsonProcessingException e) {
      throw new IllegalStateException("Class scope serialization failed", e);
    }
  }

  List<String> parse(String value) {
    if (value == null) return List.of();
    try {
      return mapper.readValue(value, new TypeReference<List<String>>() {});
    } catch (JsonProcessingException e) {
      throw new IllegalStateException("Stored class scope cannot be read", e);
    }
  }
}
