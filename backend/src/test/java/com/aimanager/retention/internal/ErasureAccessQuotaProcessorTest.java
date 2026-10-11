package com.aimanager.retention.internal;

import static org.junit.jupiter.api.Assertions.*;

import com.aimanager.retention.ErasureLedger;
import java.util.*;
import java.util.concurrent.*;
import org.junit.jupiter.api.*;
import org.springframework.jdbc.core.JdbcTemplate;

class ErasureAccessQuotaProcessorTest {
  ErasureObservationProcessorTest fixture;
  JdbcTemplate db;
  ErasureAccessQuotaProcessor processor;
  String tenant, subject, peer, app, policy, version;
  static final List<String> TABLES =
      List.of(
          "access_requests",
          "access_request_slots",
          "access_request_decisions",
          "access_window_documents",
          "access_window_receipts",
          "access_window_attempts",
          "access_window_attempt_receipts",
          "quota_calendars",
          "quota_pools",
          "quota_leases",
          "quota_lease_pools",
          "quota_ledger",
          "quota_outbox",
          "quota_plans",
          "quota_plan_revisions");

  record Graph(String request, String document, String plan, String pool, String lease) {}

  String id() {
    return UUID.randomUUID().toString();
  }

  @BeforeEach
  void setup() {
    fixture = new ErasureObservationProcessorTest();
    fixture.setup();
    db = fixture.db;
    tenant = fixture.tenant;
    subject = fixture.subject;
    peer = fixture.peer;
    processor = new ErasureAccessQuotaProcessor(fixture.data.jobs, db, fixture.catalog);
    app = id();
    policy = id();
    version = id();
    db.update(
        "INSERT INTO application_definitions(tenant_id,id,identity_hash,definition_json)"
            + " VALUES(?,?,?,'{}')",
        tenant,
        app,
        "d".repeat(64));
    db.update(
        "INSERT INTO policy_drafts(tenant_id,id,name,kind,rules_json,created_at,updated_at)"
            + " VALUES(?,?,'shared policy','FAMILY','[]',1,1)",
        tenant,
        policy);
    String preview = id();
    db.update(
        "INSERT INTO"
            + " policy_previews(tenant_id,id,policy_id,draft_revision,hash,snapshot_json,created_at,expires_at)"
            + " VALUES(?,?,?,0,?,'{}',1,2)",
        tenant,
        preview,
        policy,
        "a".repeat(64));
    db.update(
        "INSERT INTO"
            + " policy_versions(tenant_id,id,policy_id,draft_revision,sequence_number,preview_id,preview_hash,mode,snapshot_json,created_at)"
            + " VALUES(?,?,?,0,1,?,?,'PREVIEW','{}',1)",
        tenant,
        version,
        policy,
        preview,
        "a".repeat(64));
  }

  Graph graph(ErasureObservationProcessorTest.Device device) {
    String request = id(), document = id(), plan = id(), pool = id(), lease = id();
    db.update(
        "INSERT INTO"
            + " access_requests(tenant_id,id,subject_id,device_id,registration_id,policy_id,base_version_id,base_sequence,application_id,rule_ids_json,requester_actor_id,requester_actor_key,requested_window_seconds,child_reason,state,request_expires_at,created_at,updated_at)"
            + " VALUES(?,?,?,?,?,?,?,1,?,'[]','fixture',?,60,'private reason','APPROVED',100,1,1)",
        tenant,
        request,
        device.subject(),
        device.id(),
        device.registration(),
        policy,
        version,
        app,
        "a".repeat(64));
    db.update(
        "INSERT INTO"
            + " access_request_slots(tenant_id,subject_id,registration_id,application_id,last_request_id)"
            + " VALUES(?,?,?,?,?)",
        tenant,
        device.subject(),
        device.registration(),
        app,
        request);
    db.update(
        "INSERT INTO access_request_decisions(tenant_id,request_id,decision,actor_id,decided_at)"
            + " VALUES(?,?,'APPROVED','fixture',1)",
        tenant,
        request);
    db.update(
        "INSERT INTO"
            + " access_window_documents(tenant_id,id,request_id,approval_version,action,signed_document,issued_at,delivery_state)"
            + " VALUES(?,?,?,1,'GRANT','private signed grant',1,'QUEUED')",
        tenant,
        document,
        request);
    db.update(
        "INSERT INTO access_window_receipts(tenant_id,document_id,phase,received_at)"
            + " VALUES(?,?,'RECEIVED',1)",
        tenant,
        document);
    db.update(
        "INSERT INTO"
            + " access_window_attempts(tenant_id,document_id,attempt_number,created_at,delivery_state)"
            + " VALUES(?,?,1,1,'QUEUED')",
        tenant,
        document);
    db.update(
        "INSERT INTO"
            + " access_window_attempt_receipts(tenant_id,document_id,attempt_number,phase,received_at)"
            + " VALUES(?,?,1,'RECEIVED',1)",
        tenant,
        document);
    db.update(
        "INSERT INTO quota_calendars(tenant_id,subject_id,time_zone) VALUES(?,?,'UTC')",
        tenant,
        device.subject());
    db.update(
        "INSERT INTO"
            + " quota_plans(tenant_id,id,subject_id,scope_key,time_zone,next_materialize_at,created_at)"
            + " VALUES(?,?,?,'ALL','UTC',1,1)",
        tenant,
        plan,
        device.subject());
    db.update(
        "INSERT INTO"
            + " quota_plan_revisions(tenant_id,plan_id,version,effective_from,configuration_json,created_at)"
            + " VALUES(?,?,0,'2026-10-11','private plan',1)",
        tenant,
        plan);
    db.update(
        "INSERT INTO"
            + " quota_pools(tenant_id,id,subject_id,name,scope_key,period_id,time_zone,period_start,period_end,limit_seconds,plan_id,plan_version)"
            + " VALUES(?,?,?,'private pool','ALL','2026-10-11','UTC',1,100,3600,?,0)",
        tenant,
        pool,
        device.subject(),
        plan);
    db.update(
        "INSERT INTO"
            + " quota_leases(tenant_id,id,subject_id,device_id,registration_id,application_id,request_id,request_hash,boot_id,session_id,start_tick_millis,reserved_seconds,last_tick_millis,issued_at,not_after,signed_lease)"
            + " VALUES(?,?,?,?,?,?,?,?,?,?,0,60,0,1,100,'private signed lease')",
        tenant,
        lease,
        device.subject(),
        device.id(),
        device.registration(),
        app,
        id(),
        "b".repeat(64),
        id(),
        id());
    db.update(
        "INSERT INTO quota_lease_pools(tenant_id,lease_id,pool_id) VALUES(?,?,?)",
        tenant,
        lease,
        pool);
    db.update(
        "INSERT INTO"
            + " quota_ledger(tenant_id,id,pool_id,lease_id,kind,limit_delta,used_delta,reserved_delta,occurred_at)"
            + " VALUES(?,?,?,?,'RESERVED',0,0,60,1)",
        tenant,
        id(),
        pool,
        lease);
    event(pool, "QUOTA_POOL_CREATED", "{\"poolId\":\"" + pool + "\",\"source\":\"PLAN\"}");
    event(lease, "QUOTA_RESERVED", "{\"leaseId\":\"" + lease + "\",\"reservedSeconds\":60}");
    event(plan, "QUOTA_PLAN_CREATED", "{\"planId\":\"" + plan + "\",\"version\":0}");
    return new Graph(request, document, plan, pool, lease);
  }

  String event(String aggregate, String type, String json) {
    String event = id();
    db.update(
        "INSERT INTO quota_outbox(id,tenant_id,aggregate_id,event_type,event_json,occurred_at)"
            + " VALUES(?,?,?,?,?,1)",
        event,
        tenant,
        aggregate,
        type,
        json);
    return event;
  }

  long count(String table) {
    return fixture.count(table);
  }

  long total() {
    return TABLES.stream().mapToLong(this::count).sum();
  }

  ErasureAccessQuotaProcessor.Result finish(ErasureRecoveryJobs.Claim claim, int limit) {
    for (int n = 0; n < 150; n++) {
      var result = processor.process(claim, limit);
      assertTrue(result.deletedRows() >= 0 && result.deletedRows() <= limit);
      if (result.complete()) return result;
    }
    throw new AssertionError("Processor did not finish within bounded fixture");
  }

  void failure(String code, Runnable work) {
    fixture.data.failure(code, work::run);
  }

  @Test
  void deletesAllFifteenStoresAndPreservesPeerAndSharedPolicy() {
    var target = fixture.device(subject);
    var other = fixture.device(peer);
    graph(target);
    graph(other);
    var claim = fixture.accept(target);
    var result = finish(claim, 2);
    assertEquals(17, result.totalRows());
    for (String table : TABLES)
      assertEquals(table.equals("quota_outbox") ? 3 : 1, count(table), table);
    assertEquals(1, count("policy_drafts"));
    assertEquals(1, count("policy_versions"));
    assertEquals(1, count("application_definitions"));
    var replay = finish(claim, 2);
    assertEquals(0, replay.deletedRows());
    assertEquals(result.totalRows(), replay.totalRows());
    assertTrue(replay.batches() >= result.batches());
    assertEquals(
        "CLAIMED", fixture.data.jobs.find(claim.job().entry().request().requestId()).state());
    assertEquals(ErasureLedger.WorkState.RECOVERY_REQUIRED, fixture.data.ledger.workState());
  }

  @Test
  void missingHistoricalRegistrationRejectsBeforeDeletingAnyRow() {
    var current = fixture.device(peer);
    var historical = new ErasureObservationProcessorTest.Device(current.id(), id(), subject);
    graph(historical);
    var claim = fixture.accept();
    failure("ERASURE_SCOPE_CHANGED", () -> processor.process(claim, 25));
    assertEquals(17, total());
  }

  @Test
  void oldRegistrationDataIsRemovedWithoutRemovingNewOwnersRecords() {
    var current = fixture.device(peer);
    var old = new ErasureObservationProcessorTest.Device(current.id(), id(), subject);
    graph(old);
    var retained = graph(current);
    var result = finish(fixture.accept(old), 25);
    assertEquals(17, result.totalRows());
    assertEquals(17, total());
    assertEquals(
        retained.lease(),
        db.queryForObject("SELECT id FROM quota_leases WHERE tenant_id=?", String.class, tenant));
  }

  @Test
  void crossSubjectAllocationRejectsBeforeAnyEventDeletion() {
    var target = fixture.device(subject);
    var own = graph(target);
    var other = graph(fixture.device(peer));
    db.update(
        "INSERT INTO quota_lease_pools(tenant_id,lease_id,pool_id) VALUES(?,?,?)",
        tenant,
        own.lease(),
        other.pool());
    var claim = fixture.accept(target);
    failure("ERASURE_QUOTA_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(35, total());
  }

  @Test
  void crossSubjectLedgerReferenceRejectsBeforeDeletingPeerHistory() {
    var target = fixture.device(subject);
    var own = graph(target);
    var other = graph(fixture.device(peer));
    db.update(
        "UPDATE quota_ledger SET lease_id=? WHERE tenant_id=? AND pool_id=?",
        own.lease(),
        tenant,
        other.pool());
    var claim = fixture.accept(target);
    failure("ERASURE_QUOTA_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(34, total());
  }

  @Test
  void eventPayloadCannotDisagreeWithAggregateOrHideExtraReferences() {
    var target = fixture.device(subject);
    var own = graph(target);
    db.update(
        "UPDATE quota_outbox SET event_json=? WHERE tenant_id=? AND aggregate_id=?",
        "{\"poolId\":\"" + id() + "\",\"source\":\"PLAN\"}",
        tenant,
        own.pool());
    var claim = fixture.accept(target);
    failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(17, total());
  }

  @Test
  void orphanQuotaEventCannotBeSilentlySkipped() {
    var target = fixture.device(subject);
    graph(target);
    event(id(), "QUOTA_RESERVED", "{}");
    var claim = fixture.accept(target);
    failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(18, total());
  }

  @Test
  void checkpointFailureRollsBackActualBusinessDeletes() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    JdbcTemplate broken =
        new JdbcTemplate(fixture.data.business) {
          @Override
          public int update(String sql, Object... args) {
            if (sql.startsWith("UPDATE erasure_recovery_steps"))
              throw new IllegalStateException("fixture checkpoint unavailable");
            return super.update(sql, args);
          }
        };
    var failing = new ErasureAccessQuotaProcessor(fixture.data.jobs, broken, fixture.catalog);
    assertThrows(IllegalStateException.class, () -> failing.process(claim, 25));
    assertEquals(17, total());
    assertEquals(
        0, db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_steps", Integer.class));
  }

  @Test
  void restartResumesPersistedProgressAndEveryBatchHonorsOneRowLimit() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    var first = processor.process(claim, 1);
    assertEquals(1, first.deletedRows());
    assertFalse(first.complete());
    processor = new ErasureAccessQuotaProcessor(fixture.data.jobs, db, fixture.catalog);
    assertEquals(17, finish(claim, 1).totalRows());
    assertEquals(0, total());
  }

  @Test
  void doneStepRejectsReappearedData() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    finish(claim, 25);
    assertEquals(0, total());
    db.update(
        "INSERT INTO quota_calendars(tenant_id,subject_id,time_zone) VALUES(?,?,'UTC')",
        tenant,
        subject);
    failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
  }

  @Test
  void invalidBatchSizesAreRejected() {
    var claim = fixture.accept();
    for (int size : new int[] {0, -1, 26})
      assertThrows(IllegalArgumentException.class, () -> processor.process(claim, size));
  }

  @Test
  void isolatedTenantWithIdenticalIdentifiersIsPreserved() throws Exception {
    var target = fixture.device(subject);
    graph(target);
    String other = id();
    db.update(
        "INSERT INTO tenants(id,name,kind,time_zone,created_at) VALUES(?,'other','FAMILY','UTC',1)",
        other);
    var order =
        new ArrayList<>(
            List.of(
                "subjects",
                "devices",
                "application_definitions",
                "policy_drafts",
                "policy_previews",
                "policy_versions",
                "access_requests",
                "access_request_slots",
                "access_request_decisions",
                "access_window_documents",
                "access_window_receipts",
                "access_window_attempts",
                "access_window_attempt_receipts",
                "quota_calendars",
                "quota_plans",
                "quota_plan_revisions",
                "quota_pools",
                "quota_leases",
                "quota_lease_pools",
                "quota_ledger",
                "quota_outbox"));
    for (var table : order)
      for (var row : db.queryForList("SELECT * FROM " + table + " WHERE tenant_id=?", tenant)) {
        row.put("tenant_id", other);
        if (table.equals("quota_outbox")) row.put("id", id());
        var columns = new ArrayList<>(row.keySet());
        var values = new ArrayList<Object>();
        for (var column : columns) {
          Object value = row.get(column);
          if (value instanceof java.sql.Clob clob)
            value = clob.getSubString(1, (int) clob.length());
          values.add(value);
        }
        db.update(
            "INSERT INTO "
                + table
                + "("
                + String.join(",", columns)
                + ") VALUES("
                + String.join(",", Collections.nCopies(columns.size(), "?"))
                + ")",
            values.toArray());
      }
    assertEquals(17, finish(fixture.accept(target), 25).totalRows());
    assertEquals(0, total());
    for (var table : TABLES)
      assertEquals(
          table.equals("quota_outbox") ? 3 : 1,
          db.queryForObject(
              "SELECT COUNT(*) FROM " + table + " WHERE tenant_id=?", Integer.class, other),
          table);
  }

  @Test
  void allSixSupportedEventTypesAreCleared() {
    var target = fixture.device(subject);
    var own = graph(target);
    event(own.pool(), "QUOTA_ADJUSTED", "{\"poolId\":\"" + own.pool() + "\",\"deltaSeconds\":-60}");
    event(
        own.lease(),
        "QUOTA_SETTLED",
        "{\"leaseId\":\""
            + own.lease()
            + "\",\"sequence\":1,\"cumulativeUsedSeconds\":3,\"finished\":true}");
    event(
        own.plan(),
        "QUOTA_PLAN_UPDATED",
        "{\"planId\":\"" + own.plan() + "\",\"version\":1,\"effectiveFrom\":\"2026-10-12\"}");
    assertEquals(20, finish(fixture.accept(target), 25).totalRows());
    assertEquals(0, total());
  }

  @Test
  void malformedEventVariantsCannotAdvanceCheckpoint() {
    var target = fixture.device(subject);
    var own = graph(target);
    var claim = fixture.accept(target);
    for (String payload :
        List.of(
            "null",
            "[]",
            "{",
            "{\"poolId\":\""
                + own.pool()
                + "\",\"source\":\"PLAN\",\"subjectId\":\""
                + peer
                + "\"}",
            "{\"poolId\":\"" + own.pool() + "\",\"source\":\"PLAN\",\"source\":\"MANUAL\"}",
            "{\"poolId\":\"" + own.pool() + "\",\"source\":{}}")) {
      db.update(
          "UPDATE quota_outbox SET event_json=? WHERE tenant_id=? AND aggregate_id=?",
          payload,
          tenant,
          own.pool());
      failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> processor.process(claim, 25));
      assertEquals(17, total());
      assertEquals(
          0, db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_steps", Integer.class));
    }
  }

  @Test
  void oversizedValidPayloadIsRejectedBeforeDeletion() throws Exception {
    var target = fixture.device(subject);
    var own = graph(target);
    var claim = fixture.accept(target);
    String payload = " ".repeat(65537) + "{\"poolId\":\"" + own.pool() + "\",\"source\":\"PLAN\"}";
    try (var connection = fixture.data.business.getConnection()) {
      if (connection.getMetaData().getDatabaseProductName().equals("MySQL")) {
        assertThrows(
            org.springframework.dao.DataIntegrityViolationException.class,
            () ->
                db.update(
                    "UPDATE quota_outbox SET event_json=? WHERE tenant_id=? AND aggregate_id=?",
                    payload,
                    tenant,
                    own.pool()));
      } else {
        db.update(
            "UPDATE quota_outbox SET event_json=? WHERE tenant_id=? AND aggregate_id=?",
            payload,
            tenant,
            own.pool());
        failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> processor.process(claim, 25));
      }
    }
    assertEquals(17, total());
    assertEquals(
        0, db.queryForObject("SELECT COUNT(*) FROM erasure_recovery_steps", Integer.class));
  }

  @Test
  void unknownEventTypeIsRejected() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    db.update("UPDATE quota_outbox SET event_type='FUTURE_TYPE' WHERE tenant_id=?", tenant);
    failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(17, total());
  }

  @Test
  void repeatedOldEventAfterParentDeletionIsDetected() {
    var target = fixture.device(subject);
    var own = graph(target);
    var claim = fixture.accept(target);
    finish(claim, 25);
    event(
        own.lease(),
        "QUOTA_RESERVED",
        "{\"leaseId\":\"" + own.lease() + "\",\"reservedSeconds\":60}");
    failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(1, total());
  }

  @Test
  void eventReappearingAfterScanBlocksParentDeletion() {
    var target = fixture.device(subject);
    var own = graph(target);
    var claim = fixture.accept(target);
    assertEquals("DATA", processor.process(claim, 25).phase());
    event(
        own.pool(),
        "QUOTA_POOL_CREATED",
        "{\"poolId\":\"" + own.pool() + "\",\"source\":\"PLAN\"}");
    failure("ERASURE_STEP_RECHECK_REQUIRED", () -> processor.process(claim, 25));
    assertEquals(15, total());
  }

  @Test
  void sameClaimConcurrentWorkersCannotDoubleCountOrSkipRows() throws Exception {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    var executor = Executors.newFixedThreadPool(2);
    try {
      var first = executor.submit(() -> finish(claim, 2));
      var second = executor.submit(() -> finish(claim, 2));
      assertEquals(17, first.get(30, TimeUnit.SECONDS).totalRows());
      assertEquals(17, second.get(30, TimeUnit.SECONDS).totalRows());
      assertEquals(0, total());
    } finally {
      executor.shutdownNow();
    }
  }

  @Test
  void expiredWorkerCannotDeleteAfterAnotherWorkerReclaims() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    db.update("UPDATE erasure_recovery_jobs SET lease_until=1");
    var replacement = fixture.data.jobs.claim(id(), 300);
    failure("ERASURE_RECOVERY_LEASE_LOST", () -> processor.process(claim, 25));
    assertEquals(17, total());
    assertEquals(17, finish(replacement, 25).totalRows());
  }

  @Test
  void unknownStepVersionAndCorruptCursorBlockProgress() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    long before = total();
    db.update("UPDATE erasure_recovery_steps SET handler_version=2 WHERE step_code='ACCESS_QUOTA'");
    failure("ERASURE_STEP_VERSION_UNSUPPORTED", () -> processor.process(claim, 25));
    assertEquals(before, total());
    db.update(
        "UPDATE erasure_recovery_steps SET handler_version=1,cursor_id='bad-cursor' WHERE"
            + " step_code='ACCESS_QUOTA'");
    failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(before, total());
  }

  @Test
  void exhaustedCountersCannotOverflowOrDeleteRows() {
    var target = fixture.device(subject);
    graph(target);
    var claim = fixture.accept(target);
    processor.process(claim, 1);
    long before = total();
    db.update(
        "UPDATE erasure_recovery_steps SET rows_processed=? WHERE step_code='ACCESS_QUOTA'",
        Long.MAX_VALUE);
    failure("ERASURE_STEP_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(before, total());
  }

  @Test
  void unacceptedHistoricalSlotIsNotIgnoredWithoutARequest() {
    db.update(
        "INSERT INTO access_request_slots(tenant_id,subject_id,registration_id,application_id)"
            + " VALUES(?,?,?,?)",
        tenant,
        subject,
        id(),
        app);
    var claim = fixture.accept();
    failure("ERASURE_SCOPE_CHANGED", () -> processor.process(claim, 25));
    assertEquals(1, total());
  }

  @Test
  void crossSubjectPlanPoolAndRequestSlotAreRejected() {
    var target = fixture.device(subject);
    var own = graph(target);
    var other = graph(fixture.device(peer));
    var claim = fixture.accept(target);
    db.update(
        "UPDATE quota_pools SET plan_id=? WHERE tenant_id=? AND id=?",
        other.plan(),
        tenant,
        own.pool());
    failure("ERASURE_QUOTA_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(34, total());
    db.update(
        "UPDATE quota_pools SET plan_id=? WHERE tenant_id=? AND id=?",
        own.plan(),
        tenant,
        own.pool());
    db.update(
        "UPDATE access_request_slots SET last_request_id=? WHERE tenant_id=? AND subject_id=?",
        other.request(),
        tenant,
        subject);
    failure("ERASURE_SCOPE_CHANGED", () -> processor.process(claim, 25));
    assertEquals(34, total());
  }

  @Test
  void emptyScopeCompletesWithoutChangingOtherSubjects() {
    graph(fixture.device(peer));
    assertEquals(0, finish(fixture.accept(), 1).totalRows());
    assertEquals(17, total());
  }

  String notification(Graph graph, ErasureObservationProcessorTest.Device device, int version) {
    String notification = id();
    db.update(
        "INSERT INTO"
            + " notification_events(tenant_id,id,request_id,subject_id,device_id,requester_actor_key,request_version,state,occurred_at)"
            + " VALUES(?,?,?,?,?,?,?,'PENDING',1)",
        tenant,
        notification,
        graph.request(),
        device.subject(),
        device.id(),
        "a".repeat(64),
        version);
    db.update(
        "INSERT INTO notification_reads(tenant_id,notification_id,actor_key,read_at)"
            + " VALUES(?,?,?,1)",
        tenant,
        notification,
        fixture.creator);
    return notification;
  }

  long physicalTotal() {
    return total() + count("notification_events") + count("notification_reads");
  }

  @Test
  void peerNotificationAndReadBySameMemberArePreserved() {
    var target = fixture.device(subject);
    var own = graph(target);
    var other = fixture.device(peer);
    var retained = graph(other);
    notification(own, target, 0);
    String kept = notification(retained, other, 0);
    assertEquals(19, finish(fixture.accept(target), 25).totalRows());
    assertEquals(19, physicalTotal());
    assertEquals(
        kept,
        db.queryForObject(
            "SELECT id FROM notification_events WHERE tenant_id=?", String.class, tenant));
    assertEquals(
        kept,
        db.queryForObject(
            "SELECT notification_id FROM notification_reads WHERE tenant_id=?",
            String.class,
            tenant));
  }

  @Test
  void notificationsAreExplicitlyCountedAndRespectPhysicalBatchBound() {
    var target = fixture.device(subject);
    var own = graph(target);
    for (int n = 0; n < 26; n++) notification(own, target, n);
    var claim = fixture.accept(target);
    for (int n = 0; n < 150; n++) {
      long before = physicalTotal();
      var result = processor.process(claim, 1);
      assertEquals(
          result.deletedRows(),
          before - physicalTotal(),
          "Hidden cascading deletion escaped the batch");
      assertTrue(before - physicalTotal() <= 1);
      if (result.complete()) {
        assertEquals(69, result.totalRows());
        assertEquals(0, physicalTotal());
        return;
      }
    }
    fail("Processor did not complete");
  }

  @Test
  void notificationOwnershipMismatchBlocksBeforeMutation() {
    var target = fixture.device(subject);
    var own = graph(target);
    var other = fixture.device(peer);
    notification(own, other, 0);
    var claim = fixture.accept(target);
    failure("ERASURE_NOTIFICATION_SCOPE_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(19, physicalTotal());
  }

  @Test
  void doneRecheckRejectsPayloadPointingToDeletedTargetBehindPeerAggregate() {
    var target = fixture.device(subject);
    var own = graph(target);
    var retained = graph(fixture.device(peer));
    var claim = fixture.accept(target);
    finish(claim, 25);
    event(
        retained.lease(),
        "QUOTA_RESERVED",
        "{\"leaseId\":\"" + own.lease() + "\",\"reservedSeconds\":60}");
    failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(18, total());
  }

  @Test
  void dataRecheckRejectsExtraTargetReferencesBeforeDeletingRows() {
    var target = fixture.device(subject);
    graph(target);
    var retained = graph(fixture.device(peer));
    var claim = fixture.accept(target);
    assertEquals("DATA", processor.process(claim, 25).phase());
    event(
        retained.lease(),
        "QUOTA_RESERVED",
        "{\"leaseId\":\""
            + retained.lease()
            + "\",\"reservedSeconds\":60,\"subjectId\":\""
            + subject
            + "\"}");
    long before = total();
    failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> processor.process(claim, 25));
    assertEquals(before, total());
  }

  @Test
  void doneRevalidationRemainsPendingUntilEveryBoundedPageIsChecked() {
    var target = fixture.device(subject);
    var own = graph(target);
    var retained = graph(fixture.device(peer));
    var claim = fixture.accept(target);
    finish(claim, 25);
    String bad =
        event(
            retained.lease(),
            "QUOTA_RESERVED",
            "{\"leaseId\":\"" + own.lease() + "\",\"reservedSeconds\":60}");
    db.update("UPDATE quota_outbox SET id='ffffffff-ffff-ffff-ffff-ffffffffffff' WHERE id=?", bad);
    var first = processor.process(claim, 1);
    assertFalse(first.complete());
    assertEquals(0, first.deletedRows());
    processor = new ErasureAccessQuotaProcessor(fixture.data.jobs, db, fixture.catalog);
    failure("ERASURE_QUOTA_EVENT_CORRUPT", () -> finish(claim, 1));
  }
}
