package com.aimanager.idempotency;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.aimanager.shared.DomainException;
import com.aimanager.subject.Subject;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import java.util.stream.IntStream;
import org.assertj.core.api.ThrowableAssert.ThrowingCallable;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;

/** Exercises the real journal, fresh schema and transaction boundary, with no business mocks. */
class IdempotencyOwnershipTest {
  private static final String TENANT = "11111111-1111-4111-8111-111111111111";
  private static final String OTHER_TENANT = "11111111-1111-4111-8111-222222222222";
  private static final String SUBJECT = "22222222-2222-4222-8222-222222222222";
  private static final String OTHER_SUBJECT = "33333333-3333-4333-8333-333333333333";
  private static final String ACTOR = "admin-for-ownership-test";
  private static final String OPERATION = "subject.create";
  private static final String KEY = "ownership-request-1";
  private static final Map<String, ?> INPUT = Map.of("nickname", "Private child response");
  private static final Clock CLOCK =
      Clock.fixed(Instant.parse("2026-10-13T10:00:00Z"), ZoneOffset.UTC);

  private JdbcTemplate db;
  private TransactionTemplate tx;
  private IdempotencyService journal;

  @BeforeEach
  void freshDatabase() {
    var env = System.getenv();
    String url = env.getOrDefault("IDEMPOTENCY_TEST_URL",
        "jdbc:h2:mem:idempotency-ownership-" + UUID.randomUUID()
            + ";MODE=MySQL;DB_CLOSE_DELAY=-1;DATABASE_TO_LOWER=TRUE");
    if (env.containsKey("IDEMPOTENCY_TEST_URL")
        && !url.matches("jdbc:mysql://127\\.0\\.0\\.1:3308/notification_it_[a-f0-9]{32}\\?.*"))
      throw new IllegalArgumentException("Idempotency tests require isolated schemas");
    var source =
        new DriverManagerDataSource(
            url, env.getOrDefault("IDEMPOTENCY_TEST_USERNAME", "sa"),
            env.getOrDefault("IDEMPOTENCY_TEST_PASSWORD", ""));
    String vendor = env.containsKey("IDEMPOTENCY_TEST_URL") ? "mysql" : "h2";
    Flyway.configure()
        .dataSource(source)
        .locations("classpath:db/migration", "classpath:db/vendor/" + vendor)
        .load()
        .migrate();
    db = new JdbcTemplate(source);
    // Dedicated, strictly validated fixture schema: methods cannot inherit global journal copies.
    db.update("DELETE FROM idempotency_subject_owners");
    db.update("DELETE FROM idempotency_requests");
    db.update("DELETE FROM subjects");
    db.update("DELETE FROM tenants");
    tx = new TransactionTemplate(new DataSourceTransactionManager(source));
    tx.setTimeout(10);
    journal = new IdempotencyService(db, new ObjectMapper(), CLOCK);
    for (String tenant : List.of(TENANT, OTHER_TENANT)) {
      db.update(
          "INSERT INTO tenants(id,name,kind,time_zone,created_at)"
              + " VALUES(?,'Ownership fixture','FAMILY','UTC',1)",
          tenant);
    }
  }

  @Test
  void newSubjectResponseCommitsItsActualOwnerWithTheMutation() {
    var response = create(KEY, r -> ResponseOwnership.subjects(TENANT, List.of(r.id())));

    assertThat(response.id()).isEqualTo(SUBJECT);
    assertThat(db.queryForObject("SELECT nickname FROM subjects", String.class))
        .isEqualTo("Private child response");
    assertThat(state()).isEqualTo("SCOPED");
    assertThat(db.queryForObject("SELECT response_body FROM idempotency_requests", String.class))
        .contains("Private child response", SUBJECT);
    assertThat(ownerKeys()).containsExactly(ResponseOwnership.subjectKey(TENANT, SUBJECT));
    assertThat(
            db.queryForList("SELECT tenant_id FROM idempotency_subject_owners", String.class))
        .containsExactly(TENANT);
  }

  @Test
  void ownerCollectionIsDeduplicatedAndFrozenBeforeCallerChangesIt() {
    var source = new ArrayList<>(List.of(SUBJECT, SUBJECT, OTHER_SUBJECT));
    var response =
        create(
            KEY,
            ignored -> {
              var ownership = ResponseOwnership.subjects(TENANT, source);
              source.clear();
              return ownership;
            });

    assertThat(response.id()).isEqualTo(SUBJECT);
    assertThat(ownerKeys())
        .containsExactlyInAnyOrder(
            ResponseOwnership.subjectKey(TENANT, SUBJECT),
            ResponseOwnership.subjectKey(TENANT, OTHER_SUBJECT));
  }

  @Test
  void sharedResponseRetainsEachExplicitSubjectRatherThanOnlyTheFirst() {
    var response =
        tx.execute(
            status ->
                journal.execute(
                    TENANT,
                    ACTOR,
                    "shared.report",
                    KEY,
                    Map.of("selection", List.of(SUBJECT, OTHER_SUBJECT)),
                    SharedResponse.class,
                    () -> new SharedResponse(List.of(SUBJECT, OTHER_SUBJECT), "Both profiles"),
                    r -> ResponseOwnership.subjects(TENANT, r.subjectIds())));

    assertThat(response.subjectIds()).containsExactly(SUBJECT, OTHER_SUBJECT);
    assertThat(state()).isEqualTo("SCOPED");
    assertThat(ownerKeys())
        .containsExactlyInAnyOrder(
            ResponseOwnership.subjectKey(TENANT, SUBJECT),
            ResponseOwnership.subjectKey(TENANT, OTHER_SUBJECT));
  }

  @Test
  void oldSignatureRemainsUnclassifiedRatherThanPretendingPersonalDataIsShared() {
    var response =
        tx.execute(
            status ->
                journal.execute(
                    TENANT, ACTOR, OPERATION, KEY, INPUT, Subject.class, this::insertSubject));

    assertThat(response.nickname()).isEqualTo("Private child response");
    assertThat(state()).isEqualTo("UNCLASSIFIED");
    assertThat(ownerKeys()).isEmpty();
    assertThat(db.queryForObject("SELECT response_body FROM idempotency_requests", String.class))
        .contains("Private child response");
  }

  @Test
  void explicitNonSubjectResponseIsDistinguishedFromMissingAttribution() {
    var response =
        tx.execute(
            status ->
                journal.execute(
                    TENANT,
                    ACTOR,
                    "catalog.shared-label",
                    KEY,
                    Map.of("label", "Shared catalog label"),
                    String.class,
                    () -> "Shared catalog label",
                    ignored -> ResponseOwnership.nonSubject()));

    assertThat(response).isEqualTo("Shared catalog label");
    assertThat(state()).isEqualTo("NON_SUBJECT");
    assertThat(ownerKeys()).isEmpty();
  }

  @Test
  void explicitUnclassifiedResponseCannotBePromotedToNonSubject() {
    create(KEY, ignored -> ResponseOwnership.unclassified());

    assertThat(state()).isEqualTo("UNCLASSIFIED");
    assertThat(ownerKeys()).isEmpty();
  }

  @Test
  void ownershipFailureRollsBackTheAlreadyPerformedBusinessMutation() {
    var mutations = new AtomicInteger();
    assertThatThrownBy(
            () ->
                tx.execute(
                    status ->
                        journal.execute(
                            TENANT,
                            ACTOR,
                            OPERATION,
                            KEY,
                            INPUT,
                            Subject.class,
                            () -> {
                              mutations.incrementAndGet();
                              return insertSubject();
                            },
                            response -> {
                              throw new IllegalStateException("Ownership snapshot unavailable");
                            })))
        .isInstanceOf(IllegalStateException.class)
        .hasMessage("Ownership snapshot unavailable");

    assertThat(mutations).hasValue(1);
    assertNoCommittedMutationOrJournal();
  }

  @Test
  void anotherTenantsAttributionCannotAttachToThisScopesResponse() {
    assertThatThrownBy(
            () -> create(KEY, r -> ResponseOwnership.subjects(OTHER_TENANT, List.of(r.id()))))
        .isInstanceOf(RuntimeException.class);

    assertNoCommittedMutationOrJournal();
  }

  @Test
  void malformedTenantOwnershipRollsBackTheMutation() {
    assertThatThrownBy(
            () -> create(KEY, r -> ResponseOwnership.subjects("not-a-tenant-uuid", List.of(r.id()))))
        .isInstanceOf(RuntimeException.class);

    assertNoCommittedMutationOrJournal();
  }

  @Test
  void malformedSubjectOwnershipRollsBackTheMutation() {
    assertThatThrownBy(
            () -> create(KEY, r -> ResponseOwnership.subjects(TENANT, List.of("not-a-subject-uuid"))))
        .isInstanceOf(RuntimeException.class);

    assertNoCommittedMutationOrJournal();
  }

  @Test
  void scopedOwnershipCannotSilentlyAcceptAnEmptySet() {
    assertThatThrownBy(() -> create(KEY, r -> ResponseOwnership.subjects(TENANT, List.of())))
        .isInstanceOf(RuntimeException.class);

    assertNoCommittedMutationOrJournal();
  }

  @Test
  void oversizedOwnershipCannotCommitPartOfItsSubjectSet() {
    var tooMany =
        IntStream.range(0, 201)
            .mapToObj(i -> new UUID(0x4000L, 0x8000000000000000L + i).toString())
            .toList();
    assertThatThrownBy(() -> create(KEY, r -> ResponseOwnership.subjects(TENANT, tooMany)))
        .isInstanceOf(RuntimeException.class);

    assertNoCommittedMutationOrJournal();
  }

  @Test
  void maximumSharedResponseCommitsAndReplaysAllTwoHundredOwners() {
    var subjects = IntStream.range(0, 200)
        .mapToObj(i -> new UUID(0x4000L, 0x8000000000000000L + i).toString()).toList();
    var input = Map.of("selection", subjects);
    var original = org.junit.jupiter.api.Assertions.assertDoesNotThrow(() -> tx.execute(status -> journal.execute(
        TENANT, ACTOR, "shared.report", KEY, input, SharedResponse.class,
        () -> new SharedResponse(subjects, "All selected profiles"),
        response -> ResponseOwnership.subjects(TENANT, response.subjectIds()))));
    assertThat(original.subjectIds()).containsExactlyElementsOf(subjects);
    assertThat(state()).isEqualTo("SCOPED");
    assertThat(ownerKeys()).containsExactlyInAnyOrderElementsOf(
        subjects.stream().map(this::independentSubjectKey).toList());
    var replay = tx.execute(status -> journal.execute(
        TENANT, ACTOR, "shared.report", KEY, input, SharedResponse.class,
        () -> { throw new AssertionError("A cached mutation must not run"); },
        response -> { throw new AssertionError("Historical owners must not be recomputed"); }));
    assertThat(replay).isEqualTo(original);
    var recovered = tx.execute(status -> journal.findCommitted(
        TENANT, ACTOR, "shared.report", KEY, input, SharedResponse.class));
    assertThat(recovered).contains(original);
    assertThat(ownerKeys()).hasSize(200);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests", Integer.class)).isEqualTo(1);
  }

  @Test
  void repeatedOwnersDoNotConsumeDistinctSubjectCapacity() {
    var subjects = new ArrayList<String>();
    for (int i = 0; i < 200; i++) {
      var subject = new UUID(0x4000L, 0x8000000000000000L + i).toString();
      subjects.add(subject);
      subjects.add(subject);
    }
    var owners = org.junit.jupiter.api.Assertions.assertDoesNotThrow(() -> ResponseOwnership.subjects(TENANT, subjects));
    subjects.clear();
    assertThat(owners.subjectIds()).hasSize(200).isSorted().doesNotHaveDuplicates();
    assertThatThrownBy(() -> owners.subjectIds().clear()).isInstanceOf(UnsupportedOperationException.class);
  }

  @Test
  void replayAndRecoveryRejectTheTwoHundredFirstRestoredOwner() {
    var subjects = IntStream.range(0, 200)
        .mapToObj(i -> new UUID(0x4000L, 0x8000000000000000L + i).toString()).toList();
    var input = Map.of("selection", subjects);
    org.junit.jupiter.api.Assertions.assertDoesNotThrow(() -> tx.execute(status -> journal.execute(
        TENANT, ACTOR, "shared.report", KEY, input, SharedResponse.class,
        () -> new SharedResponse(subjects, "All selected profiles"),
        response -> ResponseOwnership.subjects(TENANT, response.subjectIds()))));
    db.update("INSERT INTO idempotency_subject_owners(id,scope_id,actor_key,operation_key,key_hash,tenant_id,subject_key)"
        + " SELECT ?,scope_id,actor_key,operation_key,key_hash,?,? FROM idempotency_requests",
        UUID.randomUUID().toString(), TENANT, independentSubjectKey(OTHER_SUBJECT));
    assertThatThrownBy(() -> tx.execute(status -> journal.execute(
        TENANT, ACTOR, "shared.report", KEY, input, SharedResponse.class,
        () -> { throw new AssertionError("Corrupted replay must not mutate"); },
        response -> { throw new AssertionError("Corrupted replay must not replace owners"); })))
        .isInstanceOf(IllegalStateException.class).hasMessage("Journal response ownership is invalid");
    assertThatThrownBy(() -> tx.execute(status -> journal.findCommitted(
        TENANT, ACTOR, "shared.report", KEY, input, SharedResponse.class)))
        .isInstanceOf(IllegalStateException.class).hasMessage("Journal response ownership is invalid");
    assertThat(ownerKeys()).hasSize(201);
    assertThat(state()).isEqualTo("SCOPED");
  }

  private String independentSubjectKey(String subject) {
    try {
      return java.util.HexFormat.of().formatHex(java.security.MessageDigest.getInstance("SHA-256")
          .digest(("idempotency-subject-v1\n" + TENANT + "\n" + subject)
              .getBytes(java.nio.charset.StandardCharsets.UTF_8)));
    } catch (java.security.NoSuchAlgorithmException impossible) {
      throw new AssertionError(impossible);
    }
  }

  @Test
  void cachedResponseDoesNotRepeatMutationOrRecomputeItsHistoricalOwnership() {
    var original = create(KEY, r -> ResponseOwnership.subjects(TENANT, List.of(r.id())));
    var replay =
        tx.execute(
            status ->
                journal.execute(
                    TENANT,
                    ACTOR,
                    OPERATION,
                    KEY,
                    INPUT,
                    Subject.class,
                    () -> {
                      throw new AssertionError("Cached mutation must not run");
                    },
                    response -> {
                      throw new AssertionError("Historical ownership must not be recomputed");
                    }));

    assertThat(replay).isEqualTo(original);
    assertThat(ownerKeys()).containsExactly(ResponseOwnership.subjectKey(TENANT, SUBJECT));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects", Integer.class)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests", Integer.class))
        .isEqualTo(1);
  }

  @ParameterizedTest
  @CsvSource({"false,false", "true,false", "false,true", "true,true"})
  void erasedExecuteRefusesSameOrChangedRequestEvenAfterExpiry(
      boolean changedInput, boolean expired) {
    create(KEY, r -> ResponseOwnership.subjects(TENANT, List.of(r.id())));
    eraseJournal(expired);
    var nextInput = changedInput ? Map.of("nickname", "Replacement child") : INPUT;

    assertGone(
        () ->
            tx.execute(
                status ->
                    journal.execute(
                        TENANT,
                        ACTOR,
                        OPERATION,
                        KEY,
                        nextInput,
                        Subject.class,
                        () -> {
                          throw new AssertionError("An erased key must not create another subject");
                        },
                        response -> {
                          throw new AssertionError("An erased key must not replace ownership");
                        })));
    assertErasedMarkerPreserved();
  }

  @ParameterizedTest
  @CsvSource({"false,false", "true,false", "false,true", "true,true"})
  void erasedCommittedLookupIsGoneInsteadOfMissingConflictOrRecoverable(
      boolean changedInput, boolean expired) {
    create(KEY, r -> ResponseOwnership.subjects(TENANT, List.of(r.id())));
    eraseJournal(expired);
    var nextInput = changedInput ? Map.of("nickname", "Replacement child") : INPUT;

    assertGone(
        () ->
            tx.execute(
                status ->
                    journal.findCommitted(
                        TENANT, ACTOR, OPERATION, KEY, nextInput, Subject.class)));
    assertErasedMarkerPreserved();
  }

  @Test
  void activeExpiredResponseStillRejectsReplayButRemainsAvailableForExplicitRecovery() {
    var original = create(KEY, r -> ResponseOwnership.subjects(TENANT, List.of(r.id())));
    db.update("UPDATE idempotency_requests SET expires_at=?", CLOCK.millis() - 1);

    assertThatThrownBy(
            () ->
                tx.execute(
                    status ->
                        journal.execute(
                            TENANT,
                            ACTOR,
                            OPERATION,
                            KEY,
                            INPUT,
                            Subject.class,
                            () -> {
                              throw new AssertionError("Expired mutation must not run");
                            },
                            response -> ResponseOwnership.nonSubject())))
        .isInstanceOfSatisfying(
            DomainException.class,
            failure -> {
              assertThat(failure.status()).isEqualTo(HttpStatus.CONFLICT);
              assertThat(failure.errorCode()).isEqualTo("IDEMPOTENCY_KEY_EXPIRED");
            });

    var recovery =
        tx.execute(
            status ->
                journal.findCommitted(TENANT, ACTOR, OPERATION, KEY, INPUT, Subject.class));
    assertThat(recovery).contains(original);
    assertThat(state()).isEqualTo("SCOPED");
    assertThat(ownerKeys()).containsExactly(ResponseOwnership.subjectKey(TENANT, SUBJECT));
  }

  @Test
  void differentPayloadOnAnActiveKeyStillConflictsWithoutAnotherMutation() {
    create(KEY, r -> ResponseOwnership.subjects(TENANT, List.of(r.id())));

    assertThatThrownBy(
            () ->
                tx.execute(
                    status ->
                        journal.execute(
                            TENANT,
                            ACTOR,
                            OPERATION,
                            KEY,
                            Map.of("nickname", "Replacement child"),
                            Subject.class,
                            () -> {
                              throw new AssertionError("Conflicting mutation must not run");
                            },
                            response -> ResponseOwnership.nonSubject())))
        .isInstanceOfSatisfying(
            DomainException.class,
            failure -> {
              assertThat(failure.status()).isEqualTo(HttpStatus.CONFLICT);
              assertThat(failure.errorCode()).isEqualTo("IDEMPOTENCY_KEY_CONFLICT");
            });

    assertThat(ownerKeys()).containsExactly(ResponseOwnership.subjectKey(TENANT, SUBJECT));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects", Integer.class)).isEqualTo(1);
  }

  @Test
  void absentKeyPerformsTheMutationWithoutCreatingAReplayableCopy() {
    var response = create(null, r -> ResponseOwnership.subjects(TENANT, List.of(r.id())));

    assertThat(response.id()).isEqualTo(SUBJECT);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects", Integer.class)).isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests", Integer.class))
        .isZero();
    assertThat(ownerKeys()).isEmpty();
  }

  @Test
  void ownershipDigestDoesNotExposeSubjectIdsAndSeparatesTenants() {
    String first = ResponseOwnership.subjectKey(TENANT, SUBJECT);
    String second = ResponseOwnership.subjectKey(OTHER_TENANT, SUBJECT);

    assertThat(first).matches("[0-9a-f]{64}").doesNotContain(SUBJECT);
    assertThat(second).matches("[0-9a-f]{64}").isNotEqualTo(first);
  }

  private Subject create(String key, Function<Subject, ResponseOwnership> ownership) {
    return tx.execute(
        status ->
            journal.execute(
                TENANT,
                ACTOR,
                OPERATION,
                key,
                INPUT,
                Subject.class,
                this::insertSubject,
                ownership));
  }

  private Subject insertSubject() {
    db.update(
        "INSERT INTO subjects(tenant_id,id,nickname,age_band,created_at)"
            + " VALUES(?,?,'Private child response','AGE_7_12',1)",
        TENANT,
        SUBJECT);
    return new Subject(SUBJECT, "Private child response", Subject.AgeBand.AGE_7_12, 0);
  }

  private List<String> ownerKeys() {
    return db.queryForList(
        "SELECT subject_key FROM idempotency_subject_owners ORDER BY subject_key", String.class);
  }

  private String state() {
    return db.queryForObject("SELECT response_state FROM idempotency_requests", String.class);
  }

  private void eraseJournal(boolean expired) {
    db.update(
        "UPDATE idempotency_requests SET response_state='ERASED',response_body=NULL,"
            + " actor_id='',operation='',request_hash=?,expires_at=?",
        "0".repeat(64),
        expired ? CLOCK.millis() - 1 : CLOCK.millis() + 60000);
  }

  private void assertErasedMarkerPreserved() {
    var row = db.queryForMap("SELECT * FROM idempotency_requests");
    assertThat(row.get("response_state")).isEqualTo("ERASED");
    assertThat(row.get("response_body")).isNull();
    assertThat(row.get("actor_id")).isEqualTo("");
    assertThat(row.get("operation")).isEqualTo("");
    assertThat(row.get("request_hash")).isEqualTo("0".repeat(64));
    assertThat(ownerKeys()).containsExactly(ResponseOwnership.subjectKey(TENANT, SUBJECT));
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests", Integer.class))
        .isEqualTo(1);
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects", Integer.class)).isEqualTo(1);
  }

  private void assertGone(ThrowingCallable action) {
    assertThatThrownBy(action)
        .isInstanceOfSatisfying(
            DomainException.class,
            failure -> {
              assertThat(failure.status()).isEqualTo(HttpStatus.GONE);
              assertThat(failure.errorCode()).isEqualTo("IDEMPOTENCY_RESPONSE_ERASED");
              assertThat(failure.getMessage()).doesNotContain("Private child response", SUBJECT);
            });
  }

  private void assertNoCommittedMutationOrJournal() {
    assertThat(db.queryForObject("SELECT COUNT(*) FROM subjects", Integer.class)).isZero();
    assertThat(db.queryForObject("SELECT COUNT(*) FROM idempotency_requests", Integer.class))
        .isZero();
    assertThat(ownerKeys()).isEmpty();
  }

  record SharedResponse(List<String> subjectIds, String description) {}
}
