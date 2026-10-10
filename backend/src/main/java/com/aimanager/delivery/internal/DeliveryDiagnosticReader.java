package com.aimanager.delivery.internal;

import com.aimanager.delivery.DeliveryDiagnosticSource;
import com.aimanager.fleet.Device;
import com.aimanager.shared.DomainException;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

@Service
class DeliveryDiagnosticReader implements DeliveryDiagnosticSource {
  private final JdbcTemplate jdbc;

  DeliveryDiagnosticReader(JdbcTemplate jdbc) {
    this.jdbc = jdbc;
  }

  @Override
  @Transactional(propagation = Propagation.MANDATORY)
  public List<Item> forAuthorizedDevice(String tenant, Device device) {
    var heads =
        jdbc.queryForList(
            "SELECT device_id FROM configuration_device_heads WHERE tenant_id=?"
                + " AND registration_id=? FOR UPDATE",
            String.class,
            tenant,
            device.registrationId());
    if (heads.isEmpty()) return List.of();
    if (heads.size() != 1 || !device.id().equals(heads.get(0))) throw invalid();
    var rows =
        jdbc.query(
            "SELECT d.id,d.device_id,d.registration_id,d.policy_id,s.policy_id AS stream_policy,"
                + "d.version_id,d.source_sequence,d.action,d.state,d.envelope_hash,d.issued_at,"
                + "d.delivery_expires_at,d.received_reported_at,d.stored_reported_at,d.rejection_code"
                + " FROM configuration_streams s JOIN configuration_deliveries d ON"
                + " d.tenant_id=s.tenant_id AND d.id=s.delivery_id WHERE s.tenant_id=? AND"
                + " s.registration_id=? ORDER BY s.policy_id LIMIT 101 FOR UPDATE",
            (r, n) -> {
              if (!device.id().equals(r.getString("device_id"))
                  || !device.registrationId().equals(r.getString("registration_id"))
                  || !r.getString("policy_id").equals(r.getString("stream_policy")))
                throw invalid();
              return new Item(
                  r.getString("id"),
                  r.getString("policy_id"),
                  r.getString("version_id"),
                  r.getLong("source_sequence"),
                  r.getString("action"),
                  r.getString("state"),
                  r.getString("envelope_hash"),
                  r.getLong("issued_at"),
                  r.getLong("delivery_expires_at"),
                  number(r, "received_reported_at"),
                  number(r, "stored_reported_at"),
                  r.getString("rejection_code"));
            },
            tenant,
            device.registrationId());
    if (rows.size() > 100)
      throw new DomainException(HttpStatus.PAYLOAD_TOO_LARGE, "DIAGNOSTIC_TOO_LARGE");
    return List.copyOf(rows);
  }

  private Long number(ResultSet row, String column) throws SQLException {
    var value = (Number) row.getObject(column);
    return value == null ? null : value.longValue();
  }

  private DomainException invalid() {
    return new DomainException(HttpStatus.BAD_GATEWAY, "DIAGNOSTIC_SOURCE_INVALID");
  }
}
