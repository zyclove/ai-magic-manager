package com.aimanager.commerce.internal;

import com.aimanager.audit.AuditService;
import com.aimanager.commerce.internal.CommercialFact.SourceSystem;
import com.aimanager.commerce.internal.CommercialFact.State;
import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.aimanager.tenant.TenantAccess;
import com.aimanager.tenant.TenantAccess.Role;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Clock;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;
import org.slf4j.MDC;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Institution contract review and tenant acceptance. The only entitlement write occurs after a
 * signed source fact, independent platform approval and current tenant administrator acceptance; a
 * signed revocation is applied after independent approval without requiring customer consent.
 */
@Service
class CommercialContractService {
  static final String MANAGE = "SCOPE_contract:manage";
  static final String APPROVE = "SCOPE_contract:approve";
  private final JdbcTemplate jdbc;
  private final ObjectMapper json;
  private final Clock clock;
  private final RecentAuthentication recent;
  private final TenantAccess access;
  private final CommercialLedger ledger;
  private final AuditService audit;

  CommercialContractService(
      JdbcTemplate jdbc,
      ObjectMapper json,
      Clock clock,
      RecentAuthentication recent,
      TenantAccess access,
      CommercialLedger ledger,
      AuditService audit) {
    this.jdbc = jdbc;
    this.json = json;
    this.clock = clock;
    this.recent = recent;
    this.access = access;
    this.ledger = ledger;
    this.audit = audit;
  }

  static void require(Authentication authentication, String scope) {
    if (authentication == null
        || authentication.getAuthorities().stream()
            .noneMatch(authority -> authority.getAuthority().equals(scope))) {
      throw DomainException.denied();
    }
  }

  static void requireEither(Authentication authentication) {
    if (authentication == null
        || authentication.getAuthorities().stream()
            .noneMatch(
                authority ->
                    authority.getAuthority().equals(MANAGE)
                        || authority.getAuthority().equals(APPROVE))) {
      throw DomainException.denied();
    }
  }

  /** Called only after the external JWS has been verified outside this database transaction. */
  @Transactional(timeout = 10)
  Creation create(
      Authentication authentication, Jwt actor, String reviewId, ContractEvidence evidence) {
    require(authentication, MANAGE);
    recent.require(actor);
    String id = uuid(reviewId);
    if (evidence == null) throw DomainException.invalid("INVALID_CONTRACT_EVIDENCE");
    // An absent-key locking read takes an InnoDB gap lock under repeatable-read and can
    // deadlock concurrent first submissions. Read without a lock, then lock only an existing row.
    ReviewRow previous = find(id, false);
    if (previous != null) {
      previous = required(id, true);
      if (!previous.evidenceHash().equals(evidence.evidenceHash())
          || !previous.submittedBy().equals(actor.getSubject())) {
        throw conflict("CONTRACT_REVIEW_EXISTS");
      }
      return new Creation(view(previous), false);
    }
    checkOfferAndTenant(evidence, true);
    long now = clock.millis();
    // MySQL and H2 MySQL mode both permit an idempotent insert without poisoning the enclosing
    // transaction on a unique-key race. A collision on any evidence/source key is checked below.
    jdbc.update(
        "INSERT INTO commercial_contract_reviews("
            + "id,tenant_id,offer_id,offer_revision,contract_reference,source_revision,"
            + "evidence_event_id,evidence_hash,evidence_json,state,version,submitted_by,"
            + "created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,'PENDING_REVIEW',1,?,?,?)"
            + " ON DUPLICATE KEY UPDATE id=id",
        id,
        evidence.tenantId(),
        evidence.offerId(),
        evidence.offerRevision(),
        evidence.contractReference(),
        evidence.sourceRevision(),
        evidence.eventId(),
        evidence.evidenceHash(),
        encode(evidence),
        actor.getSubject(),
        now,
        now);
    ReviewRow created = find(id, true);
    if (created == null
        || !created.evidenceHash().equals(evidence.evidenceHash())
        || !created.submittedBy().equals(actor.getSubject())) {
      throw conflict("CONTRACT_REVIEW_EXISTS");
    }
    int events =
        jdbc.queryForObject(
            "SELECT COUNT(*) FROM commercial_contract_events WHERE review_id=?", Integer.class, id);
    if (events > 0) return new Creation(view(created), false);
    event(created, "SUBMITTED", actor.getSubject(), null);
    audit.record(created.tenantId(), actor.getSubject(), "CONTRACT_REVIEW_SUBMITTED", id);
    return new Creation(view(created), true);
  }

  @Transactional(timeout = 10)
  ReviewView approve(
      Authentication authentication, Jwt actor, String id, long expected, String reason) {
    require(authentication, APPROVE);
    recent.require(actor);
    String explanation = reason(reason);
    ReviewRow row = required(id, true);
    ResourceVersions.check(expected, row.version());
    if (!"PENDING_REVIEW".equals(row.state())) throw conflict("CONTRACT_NOT_PENDING");
    if (actor.getSubject().equals(row.submittedBy())) throw DomainException.denied();
    ContractEvidence evidence = decode(row.evidenceJson());
    CommercialOfferDraft offer = checkOfferAndTenant(evidence, true);
    String nextState;
    if (evidence.state() == State.REVOKED) {
      requirePriorSource(evidence);
      ledger.apply(fact(evidence, offer, actor.getSubject()));
      nextState = "APPLIED";
    } else {
      nextState = "AWAITING_CUSTOMER";
    }
    jdbc.update(
        "UPDATE commercial_contract_reviews SET state=?,version=version+1,approved_by=?,"
            + "updated_at=? WHERE id=?",
        nextState,
        actor.getSubject(),
        clock.millis(),
        row.id());
    ReviewRow updated = required(row.id(), true);
    event(
        updated,
        evidence.state() == State.REVOKED ? "REVOKED" : "APPROVED",
        actor.getSubject(),
        explanation);
    audit.record(
        updated.tenantId(),
        actor.getSubject(),
        evidence.state() == State.REVOKED ? "CONTRACT_REVOKED" : "CONTRACT_REVIEW_APPROVED",
        updated.id());
    return view(updated);
  }

  @Transactional(timeout = 10)
  ReviewView reject(
      Authentication authentication, Jwt actor, String id, long expected, String reason) {
    require(authentication, APPROVE);
    recent.require(actor);
    String explanation = reason(reason);
    ReviewRow row = required(id, true);
    ResourceVersions.check(expected, row.version());
    if (!"PENDING_REVIEW".equals(row.state())) throw conflict("CONTRACT_NOT_PENDING");
    if (actor.getSubject().equals(row.submittedBy())) throw DomainException.denied();
    jdbc.update(
        "UPDATE commercial_contract_reviews SET state='REJECTED',version=version+1,"
            + "approved_by=?,updated_at=? WHERE id=?",
        actor.getSubject(),
        clock.millis(),
        row.id());
    ReviewRow updated = required(row.id(), true);
    event(updated, "REJECTED", actor.getSubject(), explanation);
    audit.record(updated.tenantId(), actor.getSubject(), "CONTRACT_REVIEW_REJECTED", updated.id());
    return view(updated);
  }

  @Transactional(timeout = 10)
  TenantReviewView accept(String tenantId, Jwt actor, String id, long expected) {
    access.requireWriteRole(tenantId, actor.getSubject(), Role.OWNER, Role.ORG_ADMIN);
    recent.require(actor);
    ReviewRow row = required(id, true);
    if (!row.tenantId().equals(tenantId)) throw DomainException.denied();
    ResourceVersions.check(expected, row.version());
    if (!"AWAITING_CUSTOMER".equals(row.state())) throw conflict("CONTRACT_NOT_AWAITING_CUSTOMER");
    if (actor.getSubject().equals(row.submittedBy())
        || actor.getSubject().equals(row.approvedBy())) {
      throw DomainException.denied();
    }
    ContractEvidence evidence = decode(row.evidenceJson());
    if (evidence.state() != State.ACTIVE || evidence.expiresAt() <= clock.millis()) {
      throw conflict("CONTRACT_NOT_ACTIVE");
    }
    CommercialOfferDraft offer = checkOfferAndTenant(evidence, true);
    ledger.apply(fact(evidence, offer, row.approvedBy()));
    jdbc.update(
        "UPDATE commercial_contract_reviews SET state='APPLIED',version=version+1,"
            + "accepted_by=?,updated_at=? WHERE id=?",
        actor.getSubject(),
        clock.millis(),
        row.id());
    ReviewRow updated = required(row.id(), true);
    event(updated, "CUSTOMER_ACCEPTED", actor.getSubject(), null);
    audit.record(tenantId, actor.getSubject(), "CONTRACT_CUSTOMER_ACCEPTED", updated.id());
    return tenantView(updated);
  }

  @Transactional(readOnly = true, timeout = 10)
  ReviewView platformGet(Authentication authentication, String id) {
    requireEither(authentication);
    return view(required(id, false));
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<ReviewView> platformList(Authentication authentication, int limit, String cursor) {
    requireEither(authentication);
    ItemPage.validate(limit, cursor);
    List<ReviewView> rows =
        jdbc.query(
            "SELECT * FROM commercial_contract_reviews WHERE id>? ORDER BY id LIMIT ?",
            (result, index) -> view(map(result)),
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(rows, limit, ReviewView::id);
  }

  @Transactional(readOnly = true, timeout = 10)
  TenantReviewView tenantGet(String tenantId, String actorId, String id) {
    access.requireRole(tenantId, actorId, Role.OWNER, Role.ORG_ADMIN, Role.AUDITOR);
    ReviewRow row = required(id, false);
    if (!row.tenantId().equals(tenantId)) throw DomainException.denied();
    return tenantView(row);
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<TenantReviewView> tenantList(String tenantId, String actorId, int limit, String cursor) {
    access.requireRole(tenantId, actorId, Role.OWNER, Role.ORG_ADMIN, Role.AUDITOR);
    ItemPage.validate(limit, cursor);
    List<TenantReviewView> rows =
        jdbc.query(
            "SELECT * FROM commercial_contract_reviews WHERE tenant_id=? AND id>? ORDER BY id LIMIT"
                + " ?",
            (result, index) -> tenantView(map(result)),
            tenantId,
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(rows, limit, TenantReviewView::id);
  }

  private CommercialOfferDraft checkOfferAndTenant(ContractEvidence evidence, boolean lock) {
    List<String> kinds =
        jdbc.query(
            "SELECT kind FROM tenants WHERE id=?",
            (result, index) -> result.getString(1),
            evidence.tenantId());
    if (kinds.size() != 1 || !"ORGANIZATION".equals(kinds.get(0))) {
      throw DomainException.invalid("INVALID_CONTRACT_TENANT");
    }
    List<OfferRecord> rows =
        jdbc.query(
            "SELECT state,revision,payload_json,updated_at FROM commercial_catalog_offers"
                + " WHERE id=?"
                + (lock ? " FOR UPDATE" : ""),
            (result, index) ->
                new OfferRecord(
                    result.getString(1), result.getLong(2), result.getString(3), result.getLong(4)),
            evidence.offerId());
    if (rows.size() != 1) throw DomainException.invalid("INVALID_CONTRACT_OFFER");
    OfferRecord row = rows.get(0);
    CommercialOfferDraft offer;
    try {
      offer = json.readValue(row.payloadJson(), CommercialOfferDraft.class);
    } catch (JsonProcessingException malformed) {
      throw new IllegalStateException("Stored catalog offer cannot be read", malformed);
    }
    boolean active = evidence.state() == State.ACTIVE;
    if (row.revision() != evidence.offerRevision()
        || !("APPROVED".equals(row.state()) || (!active && "RETIRED".equals(row.state())))
        || !"CN".equals(offer.region())
        || offer.channel() != CommercialOfferDraft.Channel.CONTRACT
        || offer.buyerKind() != CommercialOfferDraft.BuyerKind.ORGANIZATION
        || offer.priceType() != CommercialOfferDraft.PriceType.QUOTE
        || !"CNY".equals(offer.currency())
        || offer.capacityKind() != evidence.capacityKind()
        || offer.deviceCapacity() != evidence.deviceCapacity()
        || !offer.features().equals(evidence.features())
        || (active && evidence.expiresAt() <= clock.millis())
        || (active
            && (evidence.executedAt() < row.updatedAt()
                || evidence.executedAt() < offer.availableFrom()
                || evidence.executedAt() >= offer.availableUntil()))) {
      throw conflict("CONTRACT_OFFER_MISMATCH");
    }
    return offer;
  }

  private void requirePriorSource(ContractEvidence evidence) {
    String sourceKey = sha256("CONTRACT\u0000" + evidence.contractReference());
    List<SourceRecord> sources =
        jdbc.query(
            "SELECT source_revision,state FROM commercial_sources WHERE tenant_id=?"
                + " AND source_system='CONTRACT' AND source_key=? FOR UPDATE",
            (result, index) -> new SourceRecord(result.getLong(1), result.getString(2)),
            evidence.tenantId(),
            sourceKey);
    if (sources.size() != 1
        || !"ACTIVE".equals(sources.get(0).state())
        || sources.get(0).revision() >= evidence.sourceRevision()) {
      throw conflict("CONTRACT_SOURCE_NOT_ACTIVE");
    }
  }

  private CommercialFact fact(
      ContractEvidence evidence, CommercialOfferDraft offer, String approver) {
    return new CommercialFact(
        evidence.tenantId(),
        SourceSystem.CONTRACT,
        evidence.contractReference(),
        evidence.sourceRevision(),
        offer.sku(),
        evidence.capacityKind(),
        evidence.deviceCapacity(),
        evidence.features(),
        evidence.activeFrom(),
        evidence.expiresAt(),
        evidence.state(),
        evidence.evidenceHash(),
        approver);
  }

  private ReviewRow required(String input, boolean lock) {
    ReviewRow row = find(uuid(input), lock);
    if (row == null) throw new DomainException(HttpStatus.NOT_FOUND, "CONTRACT_REVIEW_NOT_FOUND");
    return row;
  }

  private ReviewRow find(String id, boolean lock) {
    List<ReviewRow> rows =
        jdbc.query(
            "SELECT * FROM commercial_contract_reviews WHERE id=?" + (lock ? " FOR UPDATE" : ""),
            (result, index) -> map(result),
            id);
    return rows.isEmpty() ? null : rows.get(0);
  }

  private ReviewRow map(ResultSet row) throws SQLException {
    return new ReviewRow(
        row.getString("id"),
        row.getString("tenant_id"),
        row.getString("offer_id"),
        row.getLong("offer_revision"),
        row.getString("contract_reference"),
        row.getLong("source_revision"),
        row.getString("evidence_event_id"),
        row.getString("evidence_hash"),
        row.getString("evidence_json"),
        row.getString("state"),
        row.getLong("version"),
        row.getString("submitted_by"),
        row.getString("approved_by"),
        row.getString("accepted_by"),
        row.getLong("created_at"),
        row.getLong("updated_at"));
  }

  private ReviewView view(ReviewRow row) {
    ContractEvidence evidence = decode(row.evidenceJson());
    return new ReviewView(
        row.id(),
        row.tenantId(),
        row.offerId(),
        row.offerRevision(),
        row.contractReference(),
        row.sourceRevision(),
        row.state(),
        row.version(),
        evidence.buyerReference(),
        evidence.capacityKind().name(),
        evidence.deviceCapacity(),
        evidence.features().stream().map(Enum::name).sorted().toList(),
        evidence.activeFrom(),
        evidence.expiresAt(),
        evidence.state().name(),
        row.submittedBy(),
        row.approvedBy(),
        row.acceptedBy(),
        row.createdAt(),
        row.updatedAt(),
        "APPLIED".equals(row.state()));
  }

  /** The institution sees its contract facts without internal platform operator identities. */
  private TenantReviewView tenantView(ReviewRow row) {
    ReviewView review = view(row);
    return new TenantReviewView(
        review.id(),
        review.tenantId(),
        review.offerId(),
        review.offerRevision(),
        review.contractReference(),
        review.sourceRevision(),
        review.state(),
        review.version(),
        review.buyerReference(),
        review.capacityKind(),
        review.deviceCapacity(),
        review.features(),
        review.activeFrom(),
        review.expiresAt(),
        review.sourceState(),
        review.createdAt(),
        review.updatedAt(),
        review.entitlementApplied());
  }

  private void event(ReviewRow row, String action, String actor, String reason) {
    String correlation = MDC.get("correlationId");
    jdbc.update(
        "INSERT INTO commercial_contract_events(review_id,version,event_id,action,actor_id,"
            + "reason,correlation_id,occurred_at) VALUES(?,?,?,?,?,?,?,?)",
        row.id(),
        row.version(),
        UUID.randomUUID().toString(),
        action,
        actor,
        reason,
        correlation == null ? UUID.randomUUID().toString() : correlation,
        clock.millis());
  }

  private ContractEvidence decode(String value) {
    try {
      return json.readValue(value, ContractEvidence.class);
    } catch (JsonProcessingException malformed) {
      throw new IllegalStateException("Stored contract evidence cannot be read", malformed);
    }
  }

  private String encode(ContractEvidence evidence) {
    try {
      return json.writeValueAsString(evidence);
    } catch (JsonProcessingException malformed) {
      throw new IllegalStateException("Verified contract evidence cannot be encoded", malformed);
    }
  }

  private static String uuid(String value) {
    try {
      if (value == null || !UUID.fromString(value).toString().equals(value)) {
        throw new IllegalArgumentException();
      }
      return value;
    } catch (IllegalArgumentException malformed) {
      throw DomainException.invalid("INVALID_CONTRACT_REVIEW_ID");
    }
  }

  private static String reason(String value) {
    if (value == null
        || value.strip().length() < 5
        || value.strip().length() > 500
        || value.chars().anyMatch(Character::isISOControl)) {
      throw DomainException.invalid("INVALID_CONTRACT_REASON");
    }
    return value.strip();
  }

  private static String sha256(String text) {
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException unavailable) {
      throw new IllegalStateException("SHA-256 unavailable", unavailable);
    }
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private record OfferRecord(String state, long revision, String payloadJson, long updatedAt) {}

  private record SourceRecord(long revision, String state) {}

  private record ReviewRow(
      String id,
      String tenantId,
      String offerId,
      long offerRevision,
      String contractReference,
      long sourceRevision,
      String evidenceEventId,
      String evidenceHash,
      String evidenceJson,
      String state,
      long version,
      String submittedBy,
      String approvedBy,
      String acceptedBy,
      long createdAt,
      long updatedAt) {}

  record ReviewView(
      String id,
      String tenantId,
      String offerId,
      long offerRevision,
      String contractReference,
      long sourceRevision,
      String state,
      long version,
      String buyerReference,
      String capacityKind,
      int deviceCapacity,
      List<String> features,
      long activeFrom,
      long expiresAt,
      String sourceState,
      String submittedBy,
      String approvedBy,
      String acceptedBy,
      long createdAt,
      long updatedAt,
      boolean entitlementApplied) {}

  record TenantReviewView(
      String id,
      String tenantId,
      String offerId,
      long offerRevision,
      String contractReference,
      long sourceRevision,
      String state,
      long version,
      String buyerReference,
      String capacityKind,
      int deviceCapacity,
      List<String> features,
      long activeFrom,
      long expiresAt,
      String sourceState,
      long createdAt,
      long updatedAt,
      boolean entitlementApplied) {}

  record Creation(ReviewView review, boolean created) {}
}
