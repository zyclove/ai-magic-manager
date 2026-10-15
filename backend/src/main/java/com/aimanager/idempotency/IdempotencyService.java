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
import java.util.function.Function;
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
      String scopeId, String actorId, String operation, String key,
      Map<String, ?> requestAttributes, Class<T> responseType, Supplier<T> mutation) {
    return execute(scopeId, actorId, operation, key, requestAttributes, responseType,
        mutation, ignored -> ResponseOwnership.unclassified());
  }

  /** Ownership comes from the same locked business mutation, never from a later resource lookup. */
  @Transactional(timeout = 10)
  public <T> T execute(
      String scopeId, String actorId, String operation, String key,
      Map<String, ?> requestAttributes, Class<T> responseType,
      Supplier<T> mutation, Function<T, ResponseOwnership> ownership) {
    if (key == null) return mutation.get();
    validateKey(key);
    if (ownership == null) throw new IllegalArgumentException("Response ownership required");
    String keyHash = hash(key.getBytes(StandardCharsets.UTF_8));
    String actorKey = ActorKeys.key(actorId);
    String operationKey = hash(operation.getBytes(StandardCharsets.UTF_8));
    try {
      jdbc.update(
          "INSERT INTO idempotency_requests(id,scope_id,actor_id,actor_key,operation,operation_key,"
              + "key_hash,request_hash,expires_at) VALUES(?,?,?,?,?,?,?,?,?)",
          java.util.UUID.randomUUID().toString(), scopeId, actorId, actorKey, operation,
          operationKey, keyHash, "0".repeat(64), clock.instant().plusSeconds(86400).toEpochMilli());
    } catch (DuplicateKeyException duplicate) {
      var previous = jdbc.queryForMap(
          "SELECT actor_id,operation,request_hash,response_body,response_state,expires_at FROM"
              + " idempotency_requests WHERE scope_id=? AND actor_key=? AND operation_key=?"
              + " AND key_hash=? FOR UPDATE", scopeId, actorKey, operationKey, keyHash);
      // Erased keys are permanent refusal markers, including after expiry or a changed body.
      requireNotErased(previous);
      if (!fingerprint(requestAttributes).equals(previous.get("request_hash")))
        throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_CONFLICT");
      if (((Number) previous.get("expires_at")).longValue() <= clock.millis())
        throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_EXPIRED");
      if (previous.get("response_body") == null)
        throw new DomainException(HttpStatus.CONFLICT, "REQUEST_IN_PROGRESS");
      validateCommittedOwnership(scopeId, actorKey, operationKey, keyHash, previous);
      return decode(previous.get("response_body").toString(), responseType);
    }
    // Defer fingerprinting until after duplicate-state inspection so even malformed new
    // request attributes cannot turn an erased key into a recovery or mutation attempt.
    String requestHash = fingerprint(requestAttributes);
    T response = mutation.get();
    ResponseOwnership owners = ownership.apply(response);
    if (owners == null) throw new IllegalArgumentException("Response ownership required");
    if (owners.kind() == ResponseOwnership.Kind.SCOPED && !scopeId.equals(owners.tenantId()))
      throw new IllegalArgumentException("Cached response ownership is outside its tenant");
    for (String subject : owners.subjectIds()) {
      if (jdbc.update(
          "INSERT INTO idempotency_subject_owners(id,scope_id,actor_key,operation_key,key_hash,"
              + "tenant_id,subject_key) VALUES(?,?,?,?,?,?,?)", java.util.UUID.randomUUID().toString(), scopeId, actorKey, operationKey,
          keyHash, owners.tenantId(), ResponseOwnership.subjectKey(owners.tenantId(), subject)) != 1)
        throw new IllegalStateException("Cached response ownership could not be committed");
    }
    final String body;
    try {
      body = mapper.writeValueAsString(response);
    } catch (JsonProcessingException failure) {
      throw new IllegalStateException("Journal response serialization failed");
    }
    if (jdbc.update(
        "UPDATE idempotency_requests SET response_body=?,response_state=?,request_hash=?"
            + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=?"
            + " AND response_state='UNCLASSIFIED' AND response_body IS NULL",
        body, owners.kind().name(), requestHash, scopeId, actorKey, operationKey, keyHash) != 1)
      throw new IllegalStateException("Journal response could not be committed");
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
    String actorKey = ActorKeys.key(actorId);
    String operationKey = hash(operation.getBytes(StandardCharsets.UTF_8));
    String keyHash = hash(key.getBytes(StandardCharsets.UTF_8));
    var rows = jdbc.queryForList(
        "SELECT actor_id,operation,request_hash,response_body,response_state FROM idempotency_requests"
            + " WHERE scope_id=? AND actor_key=? AND operation_key=? AND key_hash=? FOR UPDATE",
        scopeId, actorKey, operationKey, keyHash);
    if (rows.isEmpty()) return Optional.empty();
    var row = rows.get(0);
    requireNotErased(row);
    if (!fingerprint(requestAttributes).equals(row.get("request_hash")))
      throw new DomainException(HttpStatus.CONFLICT, "IDEMPOTENCY_KEY_CONFLICT");
    if (row.get("response_body") == null)
      throw new DomainException(HttpStatus.CONFLICT, "REQUEST_IN_PROGRESS");
    validateCommittedOwnership(scopeId, actorKey, operationKey, keyHash, row);
    T reference = decode(row.get("response_body").toString(), responseType);
    if (reference == null) throw new IllegalStateException("Committed resource reference is missing");
    return Optional.of(reference);
  }

  private void requireNotErased(Map<String, Object> row) {
    String state = String.valueOf(row.get("response_state"));
    if (state.equals("ERASED"))
      throw new DomainException(HttpStatus.GONE, "IDEMPOTENCY_RESPONSE_ERASED");
    if (!java.util.Set.of("UNCLASSIFIED", "NON_SUBJECT", "SCOPED").contains(state))
      throw new IllegalStateException("Journal response classification is invalid");
  }

  private void validateCommittedOwnership(String scope, String actorKey, String operationKey,
      String keyHash, Map<String, Object> row) {
    if (!(row.get("actor_id") instanceof String actor)
        || !(row.get("operation") instanceof String operation)
        || !ActorKeys.key(actor).equals(actorKey)
        || !hash(operation.getBytes(StandardCharsets.UTF_8)).equals(operationKey))
      throw new IllegalStateException("Journal identity is invalid");
    var owners = jdbc.queryForList(
        "SELECT tenant_id,subject_key FROM idempotency_subject_owners WHERE scope_id=?"
            + " AND actor_key=? AND operation_key=? AND key_hash=? ORDER BY tenant_id,subject_key"
            + " LIMIT ? FOR UPDATE", scope, actorKey, operationKey, keyHash,
        ResponseOwnership.MAX_SUBJECTS + 1);
    if ("SCOPED".equals(row.get("response_state"))) {
      if (owners.isEmpty() || owners.size() > ResponseOwnership.MAX_SUBJECTS)
        throw new IllegalStateException("Journal response ownership is invalid");
      for (var owner : owners) {
        if (!scope.equals(owner.get("tenant_id")) || !canonicalUuid(scope)
            || !(owner.get("subject_key") instanceof String digest)
            || !digest.matches("[0-9a-f]{64}"))
          throw new IllegalStateException("Journal response ownership is invalid");
      }
    } else if (!owners.isEmpty()) {
      throw new IllegalStateException("Journal response ownership is invalid");
    }
  }

  private boolean canonicalUuid(String value) {
    try { return java.util.UUID.fromString(value).toString().equals(value); }
    catch (IllegalArgumentException malformed) { return false; }
  }

  private <T> T decode(String body, Class<T> responseType) {
    try { return mapper.readValue(body, responseType); }
    catch (JsonProcessingException failure) {
      // Jackson exceptions may echo private response content; do not attach their cause.
      throw new IllegalStateException("Journal response could not be read");
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
      throw new IllegalStateException("Request fingerprint serialization failed");
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
