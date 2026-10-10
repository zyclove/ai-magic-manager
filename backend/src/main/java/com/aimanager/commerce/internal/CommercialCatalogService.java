package com.aimanager.commerce.internal;

import com.aimanager.identity.RecentAuthentication;
import com.aimanager.shared.DomainException;
import com.aimanager.shared.ItemPage;
import com.aimanager.shared.ResourceVersions;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
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
 * Global operator catalog workflow. Approval only certifies a draft for later publication review;
 * this service neither opens checkout nor writes V28 commercial entitlements.
 */
@Service
class CommercialCatalogService {
  private static final String MANAGE = "SCOPE_catalog:manage";
  private static final String APPROVE = "SCOPE_catalog:approve";
  private final JdbcTemplate jdbc;
  private final ObjectMapper json;
  private final Clock clock;
  private final RecentAuthentication recent;

  CommercialCatalogService(
      JdbcTemplate jdbc, ObjectMapper json, Clock clock, RecentAuthentication recent) {
    this.jdbc = jdbc;
    this.json = json;
    this.clock = clock;
    this.recent = recent;
  }

  @Transactional(timeout = 10)
  Creation create(
      Authentication authentication, Jwt actor, String offerId, CommercialOfferDraft offer) {
    require(authentication, MANAGE);
    if (offer == null) throw DomainException.invalid("INVALID_COMMERCIAL_OFFER");
    String id = requireId(offerId);
    String actorId = actor.getSubject();
    String offerKey = offerKey(offer);
    String payload = encode(offer);
    String hash = contentHash(offer);
    long now = clock.millis();
    jdbc.update(
        "INSERT INTO commercial_catalog_offers(id,offer_key,sku,region,channel,state,revision,"
            + "payload_json,payload_hash,created_by,last_editor,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,'DRAFT',1,?,?,?,?,?,?) ON DUPLICATE KEY UPDATE id=id",
        id,
        offerKey,
        offer.sku(),
        offer.region(),
        offer.channel().name(),
        payload,
        hash,
        actorId,
        actorId,
        now,
        now);
    var existing = findRaw(id, true);
    if (existing == null
        || !existing.offerKey().equals(offerKey)
        || !existing.payloadHash().equals(hash)
        || !existing.createdBy().equals(actorId)) {
      throw new DomainException(HttpStatus.CONFLICT, "COMMERCIAL_OFFER_EXISTS");
    }
    if (existing.revision() != 1 || !"DRAFT".equals(existing.state())) {
      return new Creation(view(existing), false);
    }
    int events =
        jdbc.queryForObject(
            "SELECT COUNT(*) FROM commercial_catalog_events WHERE offer_id=?", Integer.class, id);
    if (events == 0) {
      event(existing, "CREATED", actorId, null);
      return new Creation(view(existing), true);
    }
    return new Creation(view(existing), false);
  }

  @Transactional(timeout = 10)
  OfferView revise(
      Authentication authentication,
      Jwt actor,
      String offerId,
      long expectedRevision,
      CommercialOfferDraft draft) {
    require(authentication, MANAGE);
    if (draft == null) throw DomainException.invalid("INVALID_COMMERCIAL_OFFER");
    var previous = requireRaw(offerId, true);
    ResourceVersions.check(expectedRevision, previous.revision());
    if (!"DRAFT".equals(previous.state())) {
      throw new DomainException(HttpStatus.CONFLICT, "COMMERCIAL_OFFER_NOT_DRAFT");
    }
    String key = offerKey(draft);
    String hash = contentHash(draft);
    if (hash.equals(previous.payloadHash()) && key.equals(previous.offerKey())) {
      return view(previous);
    }
    long now = clock.millis();
    try {
      jdbc.update(
          "UPDATE commercial_catalog_offers SET offer_key=?,sku=?,region=?,channel=?,"
              + "revision=revision+1,payload_json=?,payload_hash=?,last_editor=?,updated_at=?"
              + " WHERE id=?",
          key,
          draft.sku(),
          draft.region(),
          draft.channel().name(),
          encode(draft),
          hash,
          actor.getSubject(),
          now,
          previous.id());
    } catch (org.springframework.dao.DuplicateKeyException duplicate) {
      throw new DomainException(HttpStatus.CONFLICT, "COMMERCIAL_OFFER_EXISTS");
    }
    var updated = requireRaw(previous.id(), true);
    event(updated, "REVISED", actor.getSubject(), null);
    return view(updated);
  }

  @Transactional(timeout = 10)
  OfferView submit(
      Authentication authentication,
      Jwt actor,
      String offerId,
      long expectedRevision,
      String reason) {
    require(authentication, MANAGE);
    String explanation = requireReason(reason);
    var previous = requireRaw(offerId, true);
    ResourceVersions.check(expectedRevision, previous.revision());
    if (!"DRAFT".equals(previous.state())) {
      throw new DomainException(HttpStatus.CONFLICT, "COMMERCIAL_OFFER_NOT_DRAFT");
    }
    transition(previous, "IN_REVIEW", null, "SUBMITTED", actor.getSubject(), explanation);
    return view(requireRaw(previous.id(), true));
  }

  @Transactional(timeout = 10)
  OfferView approve(
      Authentication authentication,
      Jwt actor,
      String offerId,
      long expectedRevision,
      String reason) {
    require(authentication, APPROVE);
    recent.require(actor);
    String explanation = requireReason(reason);
    var previous = requireRaw(offerId, true);
    ResourceVersions.check(expectedRevision, previous.revision());
    if (!"IN_REVIEW".equals(previous.state())) {
      throw new DomainException(HttpStatus.CONFLICT, "COMMERCIAL_OFFER_NOT_IN_REVIEW");
    }
    int authored =
        jdbc.queryForObject(
            "SELECT COUNT(*) FROM commercial_catalog_events WHERE offer_id=? AND actor_id=?"
                + " AND action IN ('CREATED','REVISED','SUBMITTED')",
            Integer.class,
            previous.id(),
            actor.getSubject());
    if (authored > 0) {
      throw new DomainException(HttpStatus.FORBIDDEN, "COMMERCIAL_SELF_APPROVAL_DENIED");
    }
    transition(
        previous, "APPROVED", actor.getSubject(), "APPROVED", actor.getSubject(), explanation);
    return view(requireRaw(previous.id(), true));
  }

  @Transactional(timeout = 10)
  OfferView retire(
      Authentication authentication,
      Jwt actor,
      String offerId,
      long expectedRevision,
      String reason) {
    require(authentication, MANAGE);
    recent.require(actor);
    String explanation = requireReason(reason);
    var previous = requireRaw(offerId, true);
    ResourceVersions.check(expectedRevision, previous.revision());
    if ("RETIRED".equals(previous.state())) {
      return view(previous);
    }
    transition(
        previous, "RETIRED", previous.approvedBy(), "RETIRED", actor.getSubject(), explanation);
    return view(requireRaw(previous.id(), true));
  }

  @Transactional(readOnly = true, timeout = 10)
  OfferView get(Authentication authentication, String offerId) {
    requireEither(authentication);
    return view(requireRaw(offerId, false));
  }

  @Transactional(readOnly = true, timeout = 10)
  ItemPage<OfferView> list(Authentication authentication, int limit, String cursor) {
    requireEither(authentication);
    ItemPage.validate(limit, cursor);
    List<OfferView> rows =
        jdbc.query(
            "SELECT * FROM commercial_catalog_offers WHERE id>? ORDER BY id LIMIT ?",
            (r, i) -> view(map(r)),
            cursor == null ? "" : cursor,
            limit + 1);
    return ItemPage.from(rows, limit, OfferView::id);
  }

  @Transactional(readOnly = true, timeout = 10)
  HistoryPage history(
      Authentication authentication, String offerId, int limit, Long beforeRevision) {
    requireEither(authentication);
    var current = requireRaw(offerId, false);
    if (limit < 1 || limit > 100 || (beforeRevision != null && beforeRevision < 1)) {
      throw DomainException.invalid("INVALID_CATALOG_HISTORY_PAGE");
    }
    List<HistoryView> rows =
        jdbc.query(
            "SELECT"
                + " revision,event_id,action,actor_id,reason,correlation_id,payload_hash,payload_json,occurred_at"
                + " FROM commercial_catalog_events WHERE offer_id=? AND revision<? ORDER BY"
                + " revision DESC LIMIT ?",
            (r, i) ->
                new HistoryView(
                    r.getLong("revision"),
                    r.getString("event_id"),
                    r.getString("action"),
                    r.getString("actor_id"),
                    r.getString("reason"),
                    r.getString("correlation_id"),
                    r.getString("payload_hash"),
                    parsePayload(r.getString("payload_json")),
                    r.getLong("occurred_at")),
            current.id(),
            beforeRevision == null ? Long.MAX_VALUE : beforeRevision,
            limit + 1);
    boolean more = rows.size() > limit;
    List<HistoryView> page = List.copyOf(rows.subList(0, Math.min(limit, rows.size())));
    return new HistoryPage(page, more ? page.get(page.size() - 1).revision() : null);
  }

  private void transition(
      Raw previous, String state, String approver, String action, String actor, String reason) {
    jdbc.update(
        "UPDATE commercial_catalog_offers SET state=?,revision=revision+1,approved_by=?,"
            + "last_editor=?,updated_at=? WHERE id=?",
        state,
        approver,
        actor,
        clock.millis(),
        previous.id());
    event(requireRaw(previous.id(), true), action, actor, reason);
  }

  private void event(Raw current, String action, String actor, String reason) {
    String correlation = MDC.get("correlationId");
    jdbc.update(
        "INSERT INTO commercial_catalog_events(offer_id,revision,event_id,action,actor_id,reason,"
            + "correlation_id,payload_hash,payload_json,occurred_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
        current.id(),
        current.revision(),
        UUID.randomUUID().toString(),
        action,
        actor,
        reason,
        correlation == null ? UUID.randomUUID().toString() : correlation,
        current.payloadHash(),
        current.payloadJson(),
        clock.millis());
  }

  private Raw requireRaw(String id, boolean lock) {
    var found = findRaw(requireId(id), lock);
    if (found == null) throw DomainException.denied();
    return found;
  }

  private Raw findRaw(String id, boolean lock) {
    var rows =
        jdbc.query(
            "SELECT * FROM commercial_catalog_offers WHERE id=?" + (lock ? " FOR UPDATE" : ""),
            (r, i) -> map(r),
            id);
    return rows.isEmpty() ? null : rows.get(0);
  }

  private Raw map(java.sql.ResultSet row) throws java.sql.SQLException {
    return new Raw(
        row.getString("id"),
        row.getString("offer_key"),
        row.getString("state"),
        row.getLong("revision"),
        row.getString("payload_json"),
        row.getString("payload_hash"),
        row.getString("created_by"),
        row.getString("last_editor"),
        row.getString("approved_by"),
        row.getLong("created_at"),
        row.getLong("updated_at"));
  }

  private OfferView view(Raw raw) {
    return new OfferView(
        raw.id(),
        raw.revision(),
        raw.state(),
        parsePayload(raw.payloadJson()),
        raw.createdBy(),
        raw.lastEditor(),
        raw.approvedBy(),
        raw.createdAt(),
        raw.updatedAt(),
        false);
  }

  private JsonNode parsePayload(String payload) {
    try {
      return json.readTree(payload);
    } catch (JsonProcessingException error) {
      throw new IllegalStateException("Corrupt commercial catalog payload", error);
    }
  }

  private String encode(CommercialOfferDraft draft) {
    try {
      return json.writeValueAsString(draft);
    } catch (JsonProcessingException error) {
      throw new IllegalStateException("Cannot encode commercial offer", error);
    }
  }

  private String offerKey(CommercialOfferDraft draft) {
    return sha256(
        String.join(
            "\u0000",
            draft.sku(),
            Integer.toString(draft.skuVersion()),
            draft.region(),
            draft.channel().name(),
            draft.buyerKind().name(),
            draft.platform().name(),
            draft.deviceMode().name(),
            draft.billingPeriod().name()));
  }

  private String contentHash(CommercialOfferDraft draft) {
    String features = String.join(",", draft.features().stream().map(Enum::name).sorted().toList());
    return sha256(
        String.join(
            "\u0000",
            offerKey(draft),
            draft.priceType().name(),
            draft.currency(),
            draft.priceMinor() == null ? "QUOTE" : draft.priceMinor().toString(),
            draft.taxBasis().name(),
            draft.capacityKind().name(),
            Integer.toString(draft.deviceCapacity()),
            features,
            Long.toString(draft.availableFrom()),
            Long.toString(draft.availableUntil())));
  }

  private static String sha256(String value) {
    try {
      return HexFormat.of()
          .formatHex(
              MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8)));
    } catch (NoSuchAlgorithmException impossible) {
      throw new IllegalStateException("SHA-256 unavailable", impossible);
    }
  }

  private static String requireId(String input) {
    try {
      String parsed = UUID.fromString(input).toString();
      if (!parsed.equals(input)) throw new IllegalArgumentException();
      return parsed;
    } catch (IllegalArgumentException error) {
      throw DomainException.invalid("INVALID_COMMERCIAL_OFFER_ID");
    }
  }

  private static String requireReason(String input) {
    if (input == null) throw DomainException.invalid("INVALID_CATALOG_REASON");
    String reason = input.trim();
    if (reason.length() < 5
        || reason.length() > 500
        || reason.chars().anyMatch(Character::isISOControl)) {
      throw DomainException.invalid("INVALID_CATALOG_REASON");
    }
    return reason;
  }

  private static void require(Authentication authentication, String authority) {
    if (authentication == null
        || authentication.getAuthorities().stream()
            .noneMatch(granted -> authority.equals(granted.getAuthority()))) {
      throw DomainException.denied();
    }
  }

  private static void requireEither(Authentication authentication) {
    if (authentication == null
        || authentication.getAuthorities().stream()
            .noneMatch(
                granted ->
                    MANAGE.equals(granted.getAuthority())
                        || APPROVE.equals(granted.getAuthority()))) {
      throw DomainException.denied();
    }
  }

  record Creation(OfferView offer, boolean created) {}

  record HistoryView(
      long revision,
      String eventId,
      String action,
      String actorId,
      String reason,
      String correlationId,
      String payloadHash,
      JsonNode offer,
      long occurredAt) {}

  record HistoryPage(List<HistoryView> items, Long nextBeforeRevision) {}

  record OfferView(
      String id,
      long revision,
      String state,
      JsonNode offer,
      String createdBy,
      String lastEditor,
      String approvedBy,
      long createdAt,
      long updatedAt,
      boolean purchaseAvailable) {}

  private record Raw(
      String id,
      String offerKey,
      String state,
      long revision,
      String payloadJson,
      String payloadHash,
      String createdBy,
      String lastEditor,
      String approvedBy,
      long createdAt,
      long updatedAt) {}
}
