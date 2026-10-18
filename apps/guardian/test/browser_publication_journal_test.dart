@TestOn('browser')
library;

// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:idb_shim/idb_client_native.dart' as native;

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/browser_publication_journal.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:uuid/uuid.dart';

PublicationOwner owner({
  String actor = 'adult-a',
  String tenant = 'tenant-a',
  String api = 'https://fixture.invalid/api/v1',
  String issuer = 'https://identity.invalid/realms/manager',
}) =>
    PublicationOwner(
        actorId: actor, tenantId: tenant, apiBaseUrl: api, issuer: issuer);

PublicationIntent intent({
  PublicationOwner? scope,
  String policy = 'policy-a',
  String key = '11111111-1111-4111-8111-111111111111',
}) =>
    PublicationIntent(
        owner: scope ?? owner(),
        policyId: policy,
        revision: 7,
        previewId: '22222222-2222-4222-8222-222222222222',
        previewHash: 'a' * 64,
        previewExpiresAt: 2000,
        createdAt: 1000,
        idempotencyKey: key);

/// The first RED must be a completed assertion on the actual public journal
/// call, including the intentional implementation placeholder, not a load error.
Future<T> completed<T>(Future<T> value) async {
  Object? result;
  Object? caught;
  try {
    result = await value;
  } catch (error) {
    caught = error;
  }
  expect(caught, isNull,
      reason: 'The public journal call must complete; caught error: $caught');
  return result as T;
}

Future<void> withOwnedDatabase(
    Future<void> Function(String name, BrowserPublicationJournal first,
            BrowserPublicationJournal second)
        body) async {
  final factory = native.idbFactoryWeb;
  expect(factory, isNotNull);
  final name = 'ai-manager-publication-test-${const Uuid().v4()}';
  final first = BrowserPublicationJournal(databaseName: name);
  final second = BrowserPublicationJournal(databaseName: name);
  try {
    await body(name, first, second);
  } finally {
    // This exact UUID-named database is owned by this test. Production data is
    // never enumerated or deleted. A blocked cleanup is a fixture failure.
    expect(name.startsWith('ai-manager-publication-test-'), isTrue);
    await factory.deleteDatabase(name).timeout(const Duration(seconds: 5));
  }
}

Matcher code(String value) =>
    isA<ApiFailure>().having((failure) => failure.code, 'code', value);

void main() {
  test(
      'browser journal corrupted records fail closed without overwriting or clearing',
      () async {
    await withOwnedDatabase((name, first, second) async {
      final expected = PublicationPending(intent: intent());
      final key = '${owner().key}\u0000policy-a';
      final foreign =
          PublicationPending(intent: intent(scope: owner(actor: 'adult-b')));
      for (final raw in ['not-json', foreign.encode(), 'x' * 8193, null]) {
        final database = await native.idbFactoryWeb.open(name, version: 1,
            onUpgradeNeeded: (event) {
          final opened = event.database;
          opened.createObjectStore('pending');
        });
        try {
          if (raw == null) {
            // Seed an actually corrupt native null. idb_shim intentionally
            // rejects null values at its typed ObjectStore boundary.
            final rawDatabase = await html.window.indexedDB!.open(name);
            try {
              final transaction =
                  rawDatabase.transaction('pending', 'readwrite');
              final committed = transaction.completed;
              await transaction.objectStore('pending').put(null, key);
              await committed;
            } finally {
              rawDatabase.close();
            }
          } else {
            final transaction = database.transaction('pending', 'readwrite');
            final committed = transaction.completed;
            await transaction.objectStore('pending').put(raw, key);
            await committed;
          }
        } finally {
          database.close();
        }
        for (final call in <Future<Object?> Function()>[
          () => first.read(owner(), 'policy-a'),
          () => second.reserve(intent()),
          () => first.claimRetry(expected),
          () => second.markReauthenticationRequired(expected),
          () => first.removeIfSame(expected),
          () => second.cancelNotSubmitted(PublicationPending(
              intent: intent(),
              phase: PublicationPhase.reauthenticationRequired)),
        ]) {
          await expectLater(
              call(), throwsA(code('INVALID_POLICY_PUBLICATION_RECORD')));
        }
        final check = await native.idbFactoryWeb.open(name);
        try {
          final transaction = check.transaction('pending', 'readonly');
          final committed = transaction.completed;
          expect(await transaction.objectStore('pending').getObject(key), raw);
          await committed;
        } finally {
          check.close();
        }
      }
    });
  });

  test(
      'browser journal incompatible storage blocks all operations without memory fallback',
      () async {
    await withOwnedDatabase((name, first, second) async {
      final original = PublicationPending(intent: intent());
      final key = '${owner().key}\u0000policy-a';
      final database = await native.idbFactoryWeb.open(name, version: 2,
          onUpgradeNeeded: (event) {
        final opened = event.database;
        opened.createObjectStore('pending');
      });
      try {
        final transaction = database.transaction('pending', 'readwrite');
        final committed = transaction.completed;
        await transaction.objectStore('pending').put(original.encode(), key);
        await committed;
      } finally {
        database.close();
      }
      for (final call in <Future<Object?> Function()>[
        () => first.read(owner(), 'policy-a'),
        () => second.reserve(intent()),
        () => first.claimRetry(original),
        () => second.markReauthenticationRequired(original),
        () => first.removeIfSame(original),
        () => second.cancelNotSubmitted(PublicationPending(
            intent: intent(),
            phase: PublicationPhase.reauthenticationRequired)),
      ]) {
        await expectLater(call().timeout(const Duration(seconds: 7)),
            throwsA(code('PUBLICATION_STORAGE_UNAVAILABLE')));
      }
      final check = await native.idbFactoryWeb.open(name);
      try {
        final transaction = check.transaction('pending', 'readonly');
        final committed = transaction.completed;
        expect(await transaction.objectStore('pending').getObject(key),
            original.encode());
        expect(await transaction.objectStore('pending').count(), 1);
        await committed;
      } finally {
        check.close();
      }
    });
  });

  test(
      'browser journal attempt exhaustion keeps the durable known-not-submitted record',
      () async {
    await withOwnedDatabase((name, first, _) async {
      final exhausted = PublicationPending(
          intent: intent(),
          phase: PublicationPhase.reauthenticationRequired,
          attempt: publicationMaximumSafeInteger);
      final database = await native.idbFactoryWeb.open(name, version: 1,
          onUpgradeNeeded: (event) {
        final opened = event.database;
        opened.createObjectStore('pending');
      });
      try {
        final transaction = database.transaction('pending', 'readwrite');
        final committed = transaction.completed;
        await transaction
            .objectStore('pending')
            .put(exhausted.encode(), '${owner().key}\u0000policy-a');
        await committed;
      } finally {
        database.close();
      }
      await expectLater(first.claimRetry(exhausted),
          throwsA(code('PUBLICATION_ATTEMPT_EXHAUSTED')));
      expect(await completed(first.read(owner(), 'policy-a')), exhausted);
    });
  });

  test('browser journal capacity counts valid high UTF16 policy identifiers',
      () async {
    await withOwnedDatabase((_, first, second) async {
      for (var i = 0; i < 19; i++) {
        expect(
            (await completed(first.reserve(intent(policy: 'policy-$i'))))
                .maySubmit,
            isTrue);
      }
      final high = intent(policy: '\ufffftail');
      expect((await completed(first.reserve(high))).maySubmit, isTrue);
      await expectLater(second.reserve(intent(policy: 'policy-over-capacity')),
          throwsA(code('PUBLICATION_PENDING_CAPACITY')));
      expect((await completed(second.reserve(high))).maySubmit, isFalse);
      expect(
          (await completed(second.read(owner(), '\ufffftail')))!.intent, high);
    });
  });

  test('browser journal reads an empty owned database without a pending record',
      () async {
    await withOwnedDatabase((_, first, __) async {
      expect(await completed(first.read(owner(), 'policy-a')), isNull);
    });
  });

  test(
      'browser journal two connections reserve one policy with exactly one POST winner',
      () async {
    await withOwnedDatabase((_, first, second) async {
      final values = await completed(Future.wait([
        first.reserve(intent()),
        second.reserve(intent(key: '33333333-3333-4333-8333-333333333333')),
      ]));
      expect(values.where((value) => value.maySubmit), hasLength(1));
      expect(values.first.record, values.last.record);
      expect(values.first.record.phase, PublicationPhase.unknown);
      expect(values.first.record.attempt, 1);
      expect(await completed(second.read(owner(), 'policy-a')),
          values.first.record);
    });
  });

  test(
      'browser journal capacity is atomic at twenty while existing recovery remains readable',
      () async {
    await withOwnedDatabase((_, first, second) async {
      for (var i = 0; i < 19; i++) {
        expect(
            (await completed(first.reserve(intent(policy: 'policy-$i'))))
                .maySubmit,
            isTrue);
      }
      final results = await Future.wait([
        first
            .reserve(intent(policy: 'policy-19'))
            .then<Object>((value) => value, onError: (Object error) => error),
        second
            .reserve(intent(policy: 'policy-20'))
            .then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(results.whereType<PublicationReservation>(), hasLength(1));
      expect(results.whereType<ApiFailure>(), hasLength(1));
      expect(results.whereType<ApiFailure>().single.code,
          'PUBLICATION_PENDING_CAPACITY');
      expect(
          (await completed(second.reserve(intent(policy: 'policy-0'))))
              .maySubmit,
          isFalse);
      expect(await completed(first.read(owner(), 'policy-0')), isNotNull);
    });
  });

  test(
      'browser journal partitions actor tenant API issuer and policy without overwriting',
      () async {
    await withOwnedDatabase((_, first, second) async {
      final original = (await completed(first.reserve(intent()))).record;
      for (final scope in [
        owner(actor: 'adult-b'),
        owner(tenant: 'tenant-b'),
        owner(api: 'https://other.invalid/api/v1'),
        owner(issuer: 'https://other.invalid/realms/manager')
      ]) {
        expect(await completed(second.read(scope, 'policy-a')), isNull);
        expect(
            (await completed(second.reserve(intent(scope: scope)))).maySubmit,
            isTrue);
      }
      expect(
          (await completed(second.reserve(intent(policy: 'policy-b'))))
              .maySubmit,
          isTrue);
      expect(await completed(first.read(owner(), 'policy-a')), original);
    });
  });

  test(
      'browser journal persists a real IndexedDB record across connection close and reopen',
      () async {
    await withOwnedDatabase((name, first, _) async {
      final original = (await completed(first.reserve(intent()))).record;
      final database = await native.idbFactoryWeb.open(name);
      try {
        expect(database.objectStoreNames, contains('pending'));
        final transaction = database.transaction('pending', 'readonly');
        final committed = transaction.completed;
        final count = await transaction.objectStore('pending').count();
        await committed;
        expect(count, 1);
      } finally {
        database.close();
      }
      final reopened = BrowserPublicationJournal(databaseName: name);
      expect(await completed(reopened.read(owner(), 'policy-a')), original);
    });
  });

  test(
      'browser journal retry competition advances a known-not-submitted fence only once',
      () async {
    await withOwnedDatabase((_, first, second) async {
      final original = (await completed(first.reserve(intent()))).record;
      final denied =
          await completed(first.markReauthenticationRequired(original));
      final values = await completed(Future.wait([
        first.claimRetry(denied),
        second.claimRetry(denied),
      ]));
      expect(values.where((value) => value.maySubmit), hasLength(1));
      final current = values.firstWhere((value) => value.maySubmit).record;
      expect(current.intent, original.intent);
      expect(current.phase, PublicationPhase.unknown);
      expect(current.attempt, 2);
      expect(await completed(second.read(owner(), 'policy-a')), current);
    });
  });

  test(
      'browser journal stale 401 cleanup and cancellation cannot change a newer attempt',
      () async {
    await withOwnedDatabase((_, first, second) async {
      final original = (await completed(first.reserve(intent()))).record;
      final denied =
          await completed(first.markReauthenticationRequired(original));
      final current = (await completed(second.claimRetry(denied))).record;
      await expectLater(first.markReauthenticationRequired(original),
          throwsA(code('PUBLICATION_PENDING_CHANGED')));
      expect(await completed(first.removeIfSame(original)), isFalse);
      expect(await completed(first.removeIfSame(denied)), isFalse);
      expect(await completed(first.cancelNotSubmitted(denied)), isFalse);
      expect(await completed(first.read(owner(), 'policy-a')), current);
    });
  });

  test(
      'browser journal UNKNOWN neither expires nor cancels and never replaces its key',
      () async {
    await withOwnedDatabase((_, first, second) async {
      // Both timestamps are already in the past; journal recovery has no TTL.
      final original = (await completed(first.reserve(intent()))).record;
      expect(await completed(second.cancelNotSubmitted(original)), isFalse);
      final repeated = await completed(
          second.reserve(intent(key: '33333333-3333-4333-8333-333333333333')));
      expect(repeated.maySubmit, isFalse);
      expect(repeated.record, original);
      expect(await completed(first.read(owner(), 'policy-a')), original);
    });
  });

  test(
      'browser journal exact known-not-submitted cancellation cannot remove a later key',
      () async {
    await withOwnedDatabase((_, first, second) async {
      final original = (await completed(first.reserve(intent()))).record;
      final denied =
          await completed(first.markReauthenticationRequired(original));
      expect(await completed(first.cancelNotSubmitted(denied)), isTrue);
      final newer = (await completed(second
              .reserve(intent(key: '33333333-3333-4333-8333-333333333333'))))
          .record;
      expect(await completed(first.cancelNotSubmitted(denied)), isFalse);
      expect(await completed(first.removeIfSame(original)), isFalse);
      expect(await completed(second.read(owner(), 'policy-a')), newer);
      expect(await completed(second.removeIfSame(newer)), isTrue);
      expect(await completed(first.read(owner(), 'policy-a')), isNull);
    });
  });
}
