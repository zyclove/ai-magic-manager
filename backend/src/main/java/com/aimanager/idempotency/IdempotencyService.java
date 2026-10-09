package com.aimanager.idempotency;

import com.aimanager.identity.ActorKeys;
import com.aimanager.shared.DomainException;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.util.HexFormat;
import java.util.Map;
import java.util.Optional;
import java.util.function.Supplier;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Database uniqueness serializes retries across replicas; mutation, response and audit share one
 * transaction.
 */
@Service
public class IdempotencyService {
  private final JdbcTemplate jdbc;
  private final ObjectMapper mapper;
  private final Clock clock;

  public IdempotencyService(JdbcTemplate jdbc, ObjectMapper mapper, Clock clock) {
    this.jdbc = jdbc;
    this.mapper = mapper;
    this.clock = clock;
  }

  /**
   * Authorize BEFORE calling, including cached responses. Never journal credentials or invite
   * secrets.
   */
  @Transactional(timeout = 10)
  public <T> T execute(
      String scopeId,
      String actorId,
      String operation,
      String key,
      Map<String, ?> requestAttributes,
      Class<T> responseType,
      Supplier<T> mutation) {
    if (key == null) return mutation.get();
    validateKey(key);
    String keyHash = hash(key.getBytes(StandardCharsets.UTF_8));
    String actorKey = ActorKeys.key(actorId);
    String requestHash = fingerprint(requestAttributes);

    try {
      jdbc.update(
          "INSERT INTO"
              + " idempotency_requests(scope_id,actor_id,actor_key,operation,key_hash,request_hash,expires_at)"
              + " VALUES(?,?,?,?,?,?,?)",
          scopeId,
          actorId,
          actorKey,
          operation,
          keyHash,
          requestHash,
          clock.instant().plusSeconds(86400).toEpochMilli());
    } catch (DuplicateKeyException duplicate) {
      // Current locking read sees the winner after its transaction commits, including under MySQL
      // REPEATABLE READ.
      var previous =
          jdbc.queryForMap(
              "SELECT request_hash,response_body,expires_at FROM idempotency_requests "
                  + "WHERE scope_id=? AND actor_key=? AND operation=? AND key_hash=? FOR UPDATE",
              scopeId,
              actorKey,
              operation,
              keyHash);
      if (!requestHash.equals(previous.get("request_hash"))) {
        throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_CONFLICT");
      }
      if (((Number) previous.get("expires_at")).longValue() <= clock.millis()) {
        throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_EXPIRED");
      }
      if (previous.get("response_body") == null) {
        throw new DomainException(HttpStatus.CONFLICT, "REQUEST_IN_PROGRESS");
      }
      try {
        return mapper.readValue(previous.get("response_body").toString(), responseType);
      } catch (JsonProcessingException failure) {
        throw new IllegalStateException("Journal response could not be read", failure);
      }
    }

    T response = mutation.get();
    try {
      jdbc.update(
          "UPDATE idempotency_requests SET response_body=? WHERE scope_id=? AND actor_key=? AND"
              + " operation=? AND key_hash=?",
          mapper.writeValueAsString(response),
          scopeId,
          actorKey,
          operation,
          keyHash);
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Journal response serialization failed", failure);
    }
    return response;
  }

  /**
   * Read an existing committed resource reference, including after replay expiry. The caller must
   * hold its current authority/lifecycle locks and reauthorize the returned reference before use.
   * This never creates a journal row, renews a key or invokes the original mutation. Empty means no
   * reference is available, not proof that an external or historical mutation never happened.
   */
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public <T> Optional<T> findCommitted(
      String scopeId,
      String actorId,
      String operation,
      String key,
      Map<String, ?> requestAttributes,
      Class<T> responseType) {
    validateKey(key);
    var rows =
        jdbc.queryForList(
            "SELECT request_hash,response_body FROM idempotency_requests "
                + "WHERE scope_id=? AND actor_key=? AND operation=? AND key_hash=? FOR UPDATE",
            scopeId,
            ActorKeys.key(actorId),
            operation,
            hash(key.getBytes(StandardCharsets.UTF_8)));
    if (rows.isEmpty()) return Optional.empty();
    var row = rows.get(0);
    if (!fingerprint(requestAttributes).equals(row.get("request_hash")))
      throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_CONFLICT");
    if (row.get("response_body") == null)
      throw new DomainException(HttpStatus.CONFLICT, "REQUEST_IN_PROGRESS");
    try {
      T reference = mapper.readValue(row.get("response_body").toString(), responseType);
      if (reference == null)
        throw new IllegalStateException("Committed resource reference is missing");
      return Optional.of(reference);
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Journal response could not be read", failure);
    }
  }

  private void validateKey(String key) {
    if (key == null || key.isBlank() || key.length() > 128)
      throw DomainException.invalid("INVALID_IDEMPOTENCY_KEY");
  }

  private String fingerprint(Map<String, ?> attributes) {
    try {
      return hash(
          mapper
              .writer()
              .with(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS)
              .writeValueAsBytes(attributes));
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Request fingerprint serialization failed", failure);
    }
  }

  private String hash(byte[] bytes) {
    try {
      return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(bytes));
    } catch (NoSuchAlgorithmException failure) {
      throw new IllegalStateException("SHA-256 unavailable", failure);
    }
  }
}
