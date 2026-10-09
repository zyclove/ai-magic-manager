package com.aimanager.approval.internal;

import com.aimanager.approval.AccessRequest;
import com.aimanager.audit.AuditService;
import com.aimanager.deviceidentity.*;
import com.aimanager.fleet.*;
import com.aimanager.shared.*;
import com.aimanager.signing.ConfigurationSigner;
import com.aimanager.subject.SubjectAccess;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.sql.*;
import java.time.Clock;
import java.util.*;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Signed approval configuration transport. Device reports never certify operating-system execution.
 */
@Service
class AccessDeliveryService {
  private final JdbcTemplate db;
  private final ApprovalService approvals;
  private final DeviceAccess devices;
  private final SubjectAccess subjects;
  private final DeviceCredentials credentials;
  private final ConfigurationSigner signer;
  private final ObjectMapper mapper;
  private final AuditService audit;
  private final Clock clock;
  private final String issuer;

  AccessDeliveryService(
      JdbcTemplate db,
      ApprovalService approvals,
      DeviceAccess devices,
      SubjectAccess subjects,
      DeviceCredentials credentials,
      ConfigurationSigner signer,
      ObjectMapper mapper,
      AuditService audit,
      Clock clock,
      @Value("${manager.delivery.issuer:ai-manager}") String issuer) {
    if (issuer.isBlank() || issuer.length() > 200)
      throw new IllegalArgumentException("Invalid access document issuer");
    this.db = db;
    this.approvals = approvals;
    this.devices = devices;
    this.subjects = subjects;
    this.credentials = credentials;
    this.signer = signer;
    this.mapper = mapper;
    this.audit = audit;
    this.clock = clock;
    this.issuer = issuer;
  }

  @Transactional(timeout = 10)
  public ItemPage<Reference> list(DeviceContext identity, int limit, String cursor) {
    ItemPage.validate(limit, cursor);
    var binding = authenticate(identity);
    var ids =
        db.queryForList(
            "SELECT id FROM access_requests WHERE tenant_id=? AND device_id=? AND registration_id=?"
                + " AND subject_id=? AND issued_at IS NOT NULL AND id>? ORDER BY id LIMIT ? FOR"
                + " UPDATE",
            String.class,
            identity.tenantId(),
            identity.deviceId(),
            identity.registrationId(),
            binding.device().subjectId(),
            cursor == null ? "" : cursor,
            limit + 1);
    var page = ItemPage.from(ids, limit, id -> id);
    return new ItemPage<>(
        page.items().stream()
            .map(
                id -> {
                  var r = current(identity, binding, id);
                  return new Reference(r.id(), r.version(), r.state().name(), r.absoluteNotAfter());
                })
            .toList(),
        page.nextCursor());
  }

  @Transactional(timeout = 10)
  public Document document(DeviceContext identity, String id) {
    var binding = authenticate(identity);
    var request = current(identity, binding, id);
    if (request.issuedAt() == null) throw conflict("ACCESS_DOCUMENT_NOT_GRANTED");
    var existing = documents(identity.tenantId(), id, request.version(), true);
    if (!existing.isEmpty()) return document(existing.get(0), request);
    signer.requireConfigured();
    String documentId = UUID.randomUUID().toString();
    long issued = clock.millis();
    String action = action(request);
    var envelope =
        new Envelope(
            1,
            issuer,
            documentId,
            identity.tenantId(),
            request.id(),
            request.version(),
            request.state().name(),
            request.subjectId(),
            request.deviceId(),
            request.registrationId(),
            request.policyId(),
            request.baseVersionId(),
            request.applicationId(),
            request.ruleIds(),
            action,
            "CONFIGURE_ONLY",
            "UNCHANGED",
            request.issuedAt(),
            request.absoluteNotAfter(),
            issued);
    String signed = signer.signAccessWindow(json(envelope));
    db.update(
        "INSERT INTO"
            + " access_window_documents(tenant_id,id,request_id,approval_version,action,signed_document,issued_at,delivery_state)"
            + " VALUES(?,?,?,?,?,?,?,'SIGNED')",
        identity.tenantId(),
        documentId,
        id,
        request.version(),
        action,
        signed,
        issued);
    insertAttempt(identity.tenantId(), documentId, 1, issued);
    audit.record(
        identity.tenantId(), "device:" + identity.deviceId(), "ACCESS_DOCUMENT_SIGNED", documentId);
    return document(requireDocument(identity.tenantId(), id, documentId, false), request);
  }

  @Transactional(timeout = 10)
  public RetryResult retry(
      DeviceContext identity, String requestId, AccessDeliveryController.RetryInput input) {
    var binding = authenticate(identity);
    var request = current(identity, binding, requestId);
    var document = requireDocument(identity.tenantId(), requestId, input.documentId(), true);
    if (document.version() != request.version()) throw conflict("ACCESS_DOCUMENT_SUPERSEDED");
    var failed = attempt(document, input.failedAttempt());
    if (failed.number() < document.currentAttempt()) {
      var successor = attempt(document, failed.number() + 1);
      return new RetryResult(
          document.id(),
          successor.number(),
          successor.created(),
          successor.number() == document.currentAttempt());
    }
    var recovery = recovery(request, document, failed);
    switch (recovery.status()) {
      case "AVAILABLE" -> {}
      case "WAITING" -> throw conflict("ACCESS_RETRY_TOO_EARLY");
      case "EXHAUSTED" -> throw conflict("ACCESS_RETRY_LIMIT");
      default -> throw conflict("ACCESS_RETRY_NOT_ALLOWED");
    }
    int next = failed.number() + 1;
    long now = clock.millis();
    insertAttempt(identity.tenantId(), document.id(), next, now);
    db.update(
        "UPDATE access_window_documents SET"
            + " current_attempt=?,delivery_state='SIGNED',last_receipt_at=NULL WHERE tenant_id=?"
            + " AND id=?",
        next,
        identity.tenantId(),
        document.id());
    audit.record(
        identity.tenantId(),
        "device:" + identity.deviceId(),
        "ACCESS_DOCUMENT_RETRIED",
        document.id());
    return new RetryResult(document.id(), next, now, true);
  }

  @Transactional(timeout = 10)
  public Receipt receipt(
      DeviceContext identity, String requestId, AccessDeliveryController.Input input) {
    var binding = authenticate(identity);
    var request = current(identity, binding, requestId);
    if ((input.phase() == AccessDeliveryController.Phase.REJECTED) != (input.reasonCode() != null))
      throw DomainException.invalid("INVALID_ACCESS_RECEIPT");
    var document = requireDocument(identity.tenantId(), requestId, input.documentId(), true);
    // Legacy queued receipts always belong to attempt one, never the latest attempt.
    int number = input.deliveryAttempt() == null ? 1 : input.deliveryAttempt();
    var attempt = attempt(document, number);
    var previous =
        db.query(
            "SELECT reason_code,received_at FROM access_window_attempt_receipts WHERE tenant_id=?"
                + " AND document_id=? AND attempt_number=? AND phase=? FOR UPDATE",
            (r, n) -> new SavedReceipt(r.getString(1), r.getLong(2)),
            identity.tenantId(),
            document.id(),
            number,
            input.phase().name());
    String reason = input.reasonCode() == null ? null : input.reasonCode().name();
    if (!previous.isEmpty()) {
      if (!Objects.equals(previous.get(0).reason(), reason))
        throw conflict("ACCESS_RECEIPT_CONFLICT");
      return receiptView(
          document, number, input.phase().name(), previous.get(0).at(), request.version());
    }
    boolean first = "SIGNED".equals(attempt.state());
    boolean progressing =
        "RECEIVED".equals(attempt.state())
            && input.phase() != AccessDeliveryController.Phase.RECEIVED;
    if (!first && !progressing) throw conflict("ACCESS_RECEIPT_CONFLICT");
    long now = clock.millis();
    db.update(
        "INSERT INTO"
            + " access_window_attempt_receipts(tenant_id,document_id,attempt_number,phase,reason_code,received_at)"
            + " VALUES(?,?,?,?,?,?)",
        identity.tenantId(),
        document.id(),
        number,
        input.phase().name(),
        reason,
        now);
    db.update(
        "UPDATE access_window_attempts SET delivery_state=?,reason_code=?,last_receipt_at=? WHERE"
            + " tenant_id=? AND document_id=? AND attempt_number=?",
        input.phase().name(),
        reason,
        now,
        identity.tenantId(),
        document.id(),
        number);
    if (number == document.currentAttempt())
      db.update(
          "UPDATE access_window_documents SET delivery_state=?,last_receipt_at=? WHERE tenant_id=?"
              + " AND id=?",
          input.phase().name(),
          now,
          identity.tenantId(),
          document.id());
    audit.record(
        identity.tenantId(),
        "device:" + identity.deviceId(),
        "ACCESS_DOCUMENT_" + input.phase().name(),
        document.id());
    return receiptView(document, number, input.phase().name(), now, request.version());
  }

  @Transactional(timeout = 10)
  public Summary summary(String tenant, String actor, String id) {
    var r = approvals.get(tenant, actor, id);
    var documents = documents(tenant, id, r.version(), true);
    var d = documents.isEmpty() ? null : documents.get(0);
    var a = d == null ? null : attempt(d, d.currentAttempt());
    var recovery = d == null ? new Recovery("NOT_NEEDED", null) : recovery(r, d, a);
    return new Summary(
        id,
        r.version(),
        r.state().name(),
        r.issuedAt() == null ? null : action(r),
        d == null ? null : d.id(),
        d == null ? (r.issuedAt() == null ? "NOT_GRANTED" : "NOT_FETCHED") : d.state(),
        d == null ? null : d.receiptAt(),
        "NOT_ENFORCED",
        "DEVICE_REPORT_UNVERIFIED",
        a == null ? null : a.number(),
        a == null ? null : a.reason(),
        recovery.status(),
        recovery.retryAfter());
  }

  @Transactional(timeout = 10)
  public ItemPage<History> history(
      String tenant, String actor, String id, int limit, String cursor) {
    var r = approvals.get(tenant, actor, id);
    ItemPage.validate(limit, cursor);
    return ItemPage.from(
        db.query(
            "SELECT d.*,a.reason_code AS attempt_reason FROM access_window_documents d JOIN"
                + " access_window_attempts a ON a.tenant_id=d.tenant_id AND a.document_id=d.id AND"
                + " a.attempt_number=d.current_attempt WHERE d.tenant_id=? AND d.request_id=? AND"
                + " d.id>? ORDER BY d.id LIMIT ? FOR UPDATE",
            (row, n) -> {
              var d = row(row, n);
              return new History(
                  d.id(),
                  d.version(),
                  d.action(),
                  d.state(),
                  d.issued(),
                  d.receiptAt(),
                  d.version() == r.version(),
                  d.currentAttempt(),
                  row.getString("attempt_reason"));
            },
            tenant,
            id,
            cursor == null ? "" : cursor,
            limit + 1),
        limit,
        History::documentId);
  }

  @Transactional(timeout = 10)
  public ItemPage<Attempt> attempts(
      String tenant, String actor, String requestId, String documentId) {
    var request = approvals.get(tenant, actor, requestId);
    var d = requireDocument(tenant, requestId, documentId, true);
    var items =
        db.query(
            "SELECT * FROM access_window_attempts WHERE tenant_id=? AND document_id=? ORDER BY"
                + " attempt_number DESC LIMIT 10 FOR UPDATE",
            (row, n) -> {
              var a = attemptRow(row, n);
              return new Attempt(
                  a.number(),
                  a.created(),
                  a.state(),
                  a.reason(),
                  a.receiptAt(),
                  request.version() == d.version() && a.number() == d.currentAttempt());
            },
            tenant,
            documentId);
    return new ItemPage<>(items, null);
  }

  private void insertAttempt(String tenant, String documentId, int number, long at) {
    db.update(
        "INSERT INTO"
            + " access_window_attempts(tenant_id,document_id,attempt_number,created_at,delivery_state)"
            + " VALUES(?,?,?,?,'SIGNED')",
        tenant,
        documentId,
        number,
        at);
  }

  private Stored requireDocument(String tenant, String request, String id, boolean lock) {
    var rows =
        db.query(
            "SELECT * FROM access_window_documents WHERE tenant_id=? AND request_id=? AND id=?"
                + (lock ? " FOR UPDATE" : ""),
            this::row,
            tenant,
            request,
            id);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private AttemptRow attempt(Stored document, int number) {
    // Authentication may establish a MySQL REPEATABLE READ snapshot before waiting
    // for the document lock. Read the committed attempt under the same lock order.
    var rows =
        db.query(
            "SELECT * FROM access_window_attempts WHERE tenant_id=? AND document_id=? AND"
                + " attempt_number=? FOR UPDATE",
            this::attemptRow,
            document.tenant(),
            document.id(),
            number);
    if (rows.isEmpty()) throw DomainException.denied();
    return rows.get(0);
  }

  private AttemptRow attemptRow(ResultSet r, int n) throws SQLException {
    return new AttemptRow(
        r.getInt("attempt_number"),
        r.getLong("created_at"),
        r.getString("delivery_state"),
        r.getString("reason_code"),
        nullable(r, "last_receipt_at"));
  }

  private Recovery recovery(AccessRequest r, Stored d, AttemptRow a) {
    if (!"REJECTED".equals(a.state())) return new Recovery("NOT_NEEDED", null);
    if (!Set.of("BASELINE_MISSING", "STORAGE_FAILED").contains(a.reason()))
      return new Recovery("NOT_ALLOWED", null);
    if (a.number() >= 10) return new Recovery("EXHAUSTED", null);
    long after = a.receiptAt() + Math.min(300000L, 30000L << (a.number() - 1));
    if ("UPSERT_ACCESS_WINDOW".equals(d.action()) && after >= r.absoluteNotAfter())
      return new Recovery("WINDOW_ENDING", null);
    return new Recovery(after > clock.millis() ? "WAITING" : "AVAILABLE", after);
  }

  private Binding authenticate(DeviceContext identity) {
    var observed = devices.observeActive(identity);
    boolean active = subjects.lockForDevice(identity.tenantId(), observed.subjectId());
    var device = devices.lockActive(identity);
    if (!device.subjectId().equals(observed.subjectId())) throw conflict("ACCESS_TARGET_CHANGED");
    credentials.requireActive(identity);
    return new Binding(device, active);
  }

  private AccessRequest current(DeviceContext identity, Binding binding, String id) {
    return approvals.forDevice(identity, binding.device().subjectId(), binding.active(), id);
  }

  private String action(AccessRequest r) {
    return r.state() == AccessRequest.State.APPROVED_PENDING_DELIVERY
        ? "UPSERT_ACCESS_WINDOW"
        : "REMOVE_ACCESS_WINDOW";
  }

  private List<Stored> documents(String tenant, String id, long version, boolean lock) {
    return db.query(
        "SELECT * FROM access_window_documents WHERE tenant_id=? AND request_id=? AND"
            + " approval_version=?"
            + (lock ? " FOR UPDATE" : ""),
        this::row,
        tenant,
        id,
        version);
  }

  private Stored row(ResultSet r, int index) throws SQLException {
    return new Stored(
        r.getString("tenant_id"),
        r.getString("id"),
        r.getString("request_id"),
        r.getLong("approval_version"),
        r.getString("action"),
        r.getString("signed_document"),
        r.getLong("issued_at"),
        r.getString("delivery_state"),
        nullable(r, "last_receipt_at"),
        r.getInt("current_attempt"));
  }

  private Long nullable(ResultSet r, String field) throws SQLException {
    Number value = (Number) r.getObject(field);
    return value == null ? null : value.longValue();
  }

  private Document document(Stored d, AccessRequest r) {
    var a = attempt(d, d.currentAttempt());
    var recovery = recovery(r, d, a);
    return new Document(
        d.id(),
        d.requestId(),
        d.version(),
        d.action(),
        d.signed(),
        d.issued(),
        a.number(),
        a.state(),
        a.reason(),
        recovery.status(),
        recovery.retryAfter());
  }

  private Receipt receiptView(Stored d, int number, String phase, long at, long current) {
    return new Receipt(
        d.id(),
        d.version(),
        phase,
        at,
        d.version() == current && number == d.currentAttempt(),
        "DEVICE_REPORT_UNVERIFIED",
        "NOT_ENFORCED",
        number);
  }

  private String json(Object o) {
    try {
      return mapper.writeValueAsString(o);
    } catch (JsonProcessingException e) {
      throw new IllegalStateException("Access document encoding failed", e);
    }
  }

  private static DomainException conflict(String code) {
    return new DomainException(HttpStatus.CONFLICT, code);
  }

  private record Binding(Device device, boolean active) {}

  private record Stored(
      String tenant,
      String id,
      String requestId,
      long version,
      String action,
      String signed,
      long issued,
      String state,
      Long receiptAt,
      int currentAttempt) {}

  private record AttemptRow(
      int number, long created, String state, String reason, Long receiptAt) {}

  private record Recovery(String status, Long retryAfter) {}

  record RetryResult(String documentId, int deliveryAttempt, long createdAt, boolean current) {}

  record Attempt(
      int deliveryAttempt,
      long createdAt,
      String deliveryState,
      String reasonCode,
      Long receivedAt,
      boolean current) {}

  private record SavedReceipt(String reason, long at) {}

  record Reference(
      String requestId, long approvalVersion, String approvalState, Long absoluteNotAfter) {}

  record Document(
      String documentId,
      String requestId,
      long approvalVersion,
      String action,
      String signedDocument,
      long documentIssuedAt,
      int deliveryAttempt,
      String deliveryState,
      String reasonCode,
      String retryStatus,
      Long retryAfter) {}

  record Receipt(
      String documentId,
      long approvalVersion,
      String phase,
      long receivedAt,
      boolean current,
      String evidenceStatus,
      String executionState,
      int deliveryAttempt) {}

  record Summary(
      String requestId,
      long approvalVersion,
      String approvalState,
      String action,
      String documentId,
      String deliveryState,
      Long receivedAt,
      String executionState,
      String evidenceStatus,
      Integer deliveryAttempt,
      String reasonCode,
      String retryStatus,
      Long retryAfter) {}

  record History(
      String documentId,
      long approvalVersion,
      String action,
      String deliveryState,
      long documentIssuedAt,
      Long receivedAt,
      boolean current,
      int deliveryAttempt,
      String reasonCode) {}

  private record Envelope(
      int schemaVersion,
      String issuer,
      String documentId,
      String tenantId,
      String requestId,
      long approvalVersion,
      String approvalState,
      String subjectId,
      String deviceId,
      String registrationId,
      String policyId,
      String baseVersionId,
      String applicationId,
      List<String> ruleIds,
      String action,
      String mode,
      String quotaEffect,
      long grantIssuedAt,
      long absoluteNotAfter,
      long documentIssuedAt) {}
}
