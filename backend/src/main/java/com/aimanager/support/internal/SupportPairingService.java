package com.aimanager.support.internal;

import static com.aimanager.tenant.TenantAccess.Role.*;

import com.aimanager.audit.AuditService;
import com.aimanager.idempotency.IdempotencyService;
import com.aimanager.identity.ActorKeys;
import com.aimanager.identity.IdentityProfiles;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.TenantAccess;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;

@Service
class SupportPairingService {
  private final JdbcTemplate jdbc;
  private final RecentAuthentication recent;
  private final IdentityProfiles profiles;
  private final IdempotencyService idempotency;
  private final SupportPairingBudget budget;
  private final TenantAccess access;
  private final AuditService audit;
  private final Clock clock;

  SupportPairingService(
      JdbcTemplate jdbc,
      RecentAuthentication recent,
      IdentityProfiles profiles,
      IdempotencyService idempotency,
      SupportPairingBudget budget,
      TenantAccess access,
      AuditService audit,
      Clock clock) {
    this.jdbc = jdbc;
    this.recent = recent;
    this.profiles = profiles;
    this.idempotency = idempotency;
    this.budget = budget;
    this.access = access;
    this.audit = audit;
    this.clock = clock;
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public Created create(Jwt actor, boolean adult, String key) {
    authorize(actor, adult);
    requireKey(key);
    // Serialize creation, including simultaneous journal replays, independently of rate counters.
    // Rate attempts commit in REQUIRES_NEW and must never need a row held by this transaction.
    jdbc.update(
        "INSERT INTO support_pairing_creation_locks(actor_key) VALUES(?)"
            + " ON DUPLICATE KEY UPDATE actor_key=actor_key",
        ActorKeys.key(actor.getSubject()));
    String[] code = {null};
    var ref =
        idempotency.execute(
            "support-pairing",
            actor.getSubject(),
            "pairing.create",
            key,
            Map.of(),
            Reference.class,
            () -> {
              budget.creation(actor.getSubject());
              long now = clock.millis();
              var active =
                  jdbc.queryForList(
                      "SELECT id FROM support_pairing_requests WHERE recipient_key=? AND"
                          + " state='PENDING' AND expires_at>? ORDER BY expires_at,id LIMIT 4 FOR"
                          + " UPDATE",
                      String.class,
                      ActorKeys.key(actor.getSubject()),
                      now);
              if (active.size() >= 3)
                throw new DomainException(HttpStatus.CONFLICT, "SUPPORT_PAIRING_CAPACITY_REACHED");
              // Only the authenticated recipient's own issuer-backed display profile is read here.
              profiles.observe(actor);
              var profile = profiles.find(List.of(actor.getSubject())).get(actor.getSubject());
              String id = UUID.randomUUID().toString();
              code[0] = SupportSecrets.issue();
              jdbc.update(
                  "INSERT INTO"
                      + " support_pairing_requests(id,recipient_actor_id,recipient_key,display_name,verified_email,code_hash,state,created_at,expires_at,updated_at)"
                      + " VALUES(?,?,?,?,?,?,'PENDING',?,?,?)",
                  id,
                  actor.getSubject(),
                  ActorKeys.key(actor.getSubject()),
                  profile == null ? null : profile.displayName(),
                  profile == null ? null : profile.verifiedEmail(),
                  SupportSecrets.hash(code[0]),
                  now,
                  now + 600000,
                  now);
              event(id, actor.getSubject(), "CREATED");
              return new Reference(id);
            });
    return new Created(owned(ref.id(), actor.getSubject(), false), code[0]);
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public Pairing get(String id, Jwt actor, boolean adult) {
    authorize(actor, adult);
    return owned(id, actor.getSubject(), false);
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public ItemPage<Pairing> list(Jwt actor, boolean adult, int limit, String cursor) {
    authorize(actor, adult);
    ItemPage.validate(limit, cursor);
    var rows =
        jdbc.query(
            "SELECT * FROM support_pairing_requests WHERE recipient_key=? AND id>? ORDER BY id"
                + " LIMIT ?",
            this::map,
            ActorKeys.key(actor.getSubject()),
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(rows, limit, Pairing::id);
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public Pairing cancel(String id, Jwt actor, boolean adult, String etag, String key) {
    authorize(actor, adult);
    requireKey(key);
    var current = owned(id, actor.getSubject(), true);
    long expected = ResourceVersions.require(etag);
    var ref =
        idempotency.execute(
            "support-pairing",
            actor.getSubject(),
            "pairing.cancel",
            key,
            Map.of("id", id, "version", expected),
            Reference.class,
            () -> {
              ResourceVersions.check(expected, current.version());
              if ("CONSUMED".equals(current.state()))
                throw new DomainException(HttpStatus.CONFLICT, "SUPPORT_PAIRING_ALREADY_USED");
              if ("CANCELLED".equals(current.state())) return new Reference(id);
              String next = "EXPIRED".equals(current.state()) ? "EXPIRED" : "CANCELLED";
              jdbc.update(
                  "UPDATE support_pairing_requests SET state=?,version=version+1,updated_at=? WHERE"
                      + " id=?",
                  next,
                  clock.millis(),
                  id);
              event(id, actor.getSubject(), next);
              return new Reference(id);
            });
    return owned(ref.id(), actor.getSubject(), false);
  }

  @Transactional(isolation = Isolation.READ_COMMITTED, timeout = 10)
  public Pairing resolve(String tenant, Jwt actor, String code) {
    access.requireWriteRole(tenant, actor.getSubject(), OWNER, GUARDIAN, ORG_ADMIN);
    recent.require(actor);
    budget.resolution(actor.getSubject());
    var rows =
        jdbc.query(
            "SELECT * FROM support_pairing_requests WHERE code_hash=? FOR UPDATE",
            this::map,
            SupportSecrets.hash(code));
    if (rows.size() != 1 || !"PENDING".equals(rows.get(0).state())) throw unavailable();
    var current = rows.get(0);
    audit.record(tenant, actor.getSubject(), "SUPPORT_PAIRING_RESOLVED", current.id());
    return current;
  }

  private void authorize(Jwt actor, boolean adult) {
    if (!adult) throw DomainException.denied();
    recent.require(actor);
  }

  /**
   * Caller already holds customer membership and device lifecycle locks in the grant transaction.
   */
  @Transactional(propagation = org.springframework.transaction.annotation.Propagation.MANDATORY)
  public Pairing consume(String code, String confirmedRecipient, String customer) {
    var rows =
        jdbc.query(
            "SELECT * FROM support_pairing_requests WHERE code_hash=? FOR UPDATE",
            this::map,
            SupportSecrets.hash(code));
    if (rows.size() != 1 || !"PENDING".equals(rows.get(0).state())) throw unavailable();
    var pairing = rows.get(0);
    if (!pairing.recipientActorId().equals(confirmedRecipient))
      throw new DomainException(HttpStatus.CONFLICT, "SUPPORT_RECIPIENT_CHANGED");
    jdbc.update(
        "UPDATE support_pairing_requests SET state='CONSUMED',version=version+1,updated_at=? WHERE"
            + " id=?",
        clock.millis(),
        pairing.id());
    event(pairing.id(), customer, "CONSUMED");
    return pairing;
  }

  private void requireKey(String key) {
    if (key == null || key.isBlank() || key.length() > 128)
      throw DomainException.invalid("INVALID_IDEMPOTENCY_KEY");
  }

  private Pairing owned(String id, String actor, boolean lock) {
    var rows =
        jdbc.query(
            "SELECT * FROM support_pairing_requests WHERE id=? AND recipient_key=?"
                + (lock ? " FOR UPDATE" : ""),
            this::map,
            id,
            ActorKeys.key(actor));
    if (rows.size() != 1 || !rows.get(0).recipientActorId().equals(actor))
      throw DomainException.denied();
    return rows.get(0);
  }

  private Pairing map(ResultSet r, int row) throws SQLException {
    long expires = r.getLong("expires_at");
    String state = r.getString("state");
    if (state.equals("PENDING") && expires <= clock.millis()) state = "EXPIRED";
    return new Pairing(
        r.getString("id"),
        r.getString("recipient_actor_id"),
        r.getString("display_name"),
        r.getString("verified_email"),
        state,
        r.getLong("version"),
        r.getLong("created_at"),
        expires);
  }

  private void event(String id, String actor, String action) {
    jdbc.update(
        "INSERT INTO support_pairing_events(id,request_id,actor_key,action,occurred_at)"
            + " VALUES(?,?,?,?,?)",
        UUID.randomUUID().toString(),
        id,
        ActorKeys.key(actor),
        action,
        clock.millis());
  }

  private DomainException unavailable() {
    return new DomainException(HttpStatus.NOT_FOUND, "SUPPORT_PAIRING_UNAVAILABLE");
  }

  record Pairing(
      String id,
      String recipientActorId,
      String displayName,
      String verifiedEmail,
      String state,
      long version,
      long createdAt,
      long expiresAt) {}

  record Created(Pairing request, String code) {}

  record Reference(String id) {}
}
