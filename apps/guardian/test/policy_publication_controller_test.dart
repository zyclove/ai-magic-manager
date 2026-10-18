import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:guardian/core/policy_publication_repository.dart';
import 'package:guardian/ui/policy_publication_controller.dart';

import 'policy_publication_controller_fixtures.dart';

// Authored before the new controller; supplemental controls, not actual RED.
void main() {
  test('fresh confirmation and cancellation never create a request', () {
    final fixture = PublicationControllerFixture();
    final controller = fixture.create();
    addTearDown(controller.dispose);
    expect(controller.phase, PublicationViewPhase.fresh);
    expect(controller.beginConfirmation(), isTrue);
    expect(controller.phase, PublicationViewPhase.confirming);
    controller.cancelConfirmation();
    expect(controller.phase, PublicationViewPhase.fresh);
    expect(fixture.journal.reserves, 0);
    expect(fixture.transport.posts, isEmpty);
    expect(fixture.transport.lookups, isEmpty);
  });

  test('strict successful publish confirms and conditionally clears its record',
      () async {
    final fixture = PublicationControllerFixture();
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    expect(controller.phase, PublicationViewPhase.recorded);
    expect(controller.receipt?.state, 'CONFIGURED_NOT_ENFORCED');
    expect(fixture.preflights, 1);
    expect(fixture.transport.posts, hasLength(1));
    expect(fixture.transport.posts.single.attempt, 1);
    expect(fixture.journal.record, isNull);
    expect(fixture.journal.removals, 1);
  });

  test('queued submissions acquire busy before preflight awaits', () async {
    final fixture = PublicationControllerFixture();
    final preflight = Completer<void>();
    fixture.preflight = () => preflight.future;
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    final first = controller.submit();
    final duplicate = controller.submit();
    expect(controller.busy, isTrue);
    expect(fixture.preflights, 1);
    preflight.complete();
    await Future.wait([first, duplicate]);
    expect(fixture.journal.reserves, 1);
    expect(fixture.transport.posts, hasLength(1));
  });

  test('a preexisting atomic reservation is adopted and never posted',
      () async {
    final fixture = PublicationControllerFixture();
    final original = PublicationPending(
        intent: publicationIntent(key: '33333333-3333-4333-8333-333333333333'));
    fixture.journal.record = original;
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    expect(controller.phase, PublicationViewPhase.unknown);
    expect(controller.pending, original);
    expect(controller.intent, original.intent);
    expect(fixture.transport.posts, isEmpty);
    expect(fixture.transport.lookups, isEmpty);
  });

  test('unknown lookup remains explicit after the preview expires', () async {
    final fixture = PublicationControllerFixture();
    fixture.transport.publish = (_) async {
      throw const ApiFailure(0, 'NETWORK_ERROR');
    };
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    final original = controller.pending;
    expect(controller.phase, PublicationViewPhase.unknown);
    expect(fixture.transport.lookups, isEmpty);
    fixture.now = fixture.now.add(const Duration(days: 1));
    expect(controller.canCheck, isTrue);
    expect(controller.canConfirm, isFalse);
    await controller.check();
    await controller.check();
    expect(controller.phase, PublicationViewPhase.unknown);
    expect(fixture.transport.lookups, [original, original]);
    expect(fixture.transport.posts, hasLength(1));
    expect(fixture.journal.record, original);
  });

  test('queued queries cannot create a concurrent second GET', () async {
    final fixture = PublicationControllerFixture();
    final original = PublicationPending(intent: publicationIntent());
    fixture.journal.record = original;
    final pending = Completer<PublicationReceipt?>();
    fixture.transport.lookup = (_) => pending.future;
    final controller = fixture.create(pending: original);
    addTearDown(controller.dispose);
    expect(fixture.transport.lookups, isEmpty);
    final first = controller.check();
    final second = controller.check();
    expect(fixture.transport.lookups, hasLength(1));
    pending.complete(null);
    await Future.wait([first, second]);
    expect(controller.phase, PublicationViewPhase.unknown);
  });

  test('synchronous scope ABA permanently rejects a late result and cleanup',
      () async {
    final fixture = PublicationControllerFixture();
    final original = PublicationPending(intent: publicationIntent());
    fixture.journal.record = original;
    final pending = Completer<PublicationReceipt?>();
    fixture.transport.lookup = (_) => pending.future;
    final controller = fixture.create(pending: original);
    addTearDown(controller.dispose);
    final operation = controller.check();
    fixture.access.awayAndBack();
    expect(controller.hasAccess, isFalse);
    expect(controller.phase, PublicationViewPhase.revoked);
    pending.complete(publicationReceipt());
    await operation;
    await controller.check();
    expect(controller.receipt, isNull);
    expect(fixture.journal.removals, 0);
    expect(fixture.transport.lookups, hasLength(1));
  });

  test(
      'typed actual POST reauthentication permits only a fenced original retry',
      () async {
    final fixture = PublicationControllerFixture();
    fixture.transport.publish = (record) async {
      throw PublicationReauthenticationRequired(record);
    };
    final first = fixture.create();
    first.beginConfirmation();
    await first.submit();
    expect(first.phase, PublicationViewPhase.reauthenticationRequired);
    expect(first.needsReauth, isTrue);
    expect(first.canConfirm, isFalse);
    expect(fixture.journal.marks, 1);
    final retryable = fixture.journal.record!;
    expect(retryable.phase, PublicationPhase.reauthenticationRequired);
    first.dispose();
    fixture.transport.publish = (_) async => publicationReceipt();
    final second = fixture.create(pending: retryable);
    addTearDown(second.dispose);
    expect(second.phase, PublicationViewPhase.retryableNotSubmitted);
    expect(fixture.transport.posts, hasLength(1));
    second.beginConfirmation();
    await second.submit();
    expect(fixture.journal.claims, 1);
    expect(fixture.transport.posts, hasLength(2));
    expect(fixture.transport.posts.last.intent, retryable.intent);
    expect(fixture.transport.posts.last.attempt, retryable.attempt + 1);
    expect(second.phase, PublicationViewPhase.recorded);
  });

  test('an arbitrary 401 exception never marks an attempt retryable', () async {
    final fixture = PublicationControllerFixture();
    fixture.transport.publish = (_) async {
      throw const ApiFailure(401, 'REAUTH_REQUIRED');
    };
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    expect(
        controller.phase, PublicationViewPhase.queryReauthenticationRequired);
    expect(controller.canConfirm, isFalse);
    expect(fixture.journal.marks, 0);
    expect(fixture.journal.record?.phase, PublicationPhase.unknown);
  });

  test('lookup reauthentication never changes the persistent UNKNOWN phase',
      () async {
    final fixture = PublicationControllerFixture();
    final original = PublicationPending(intent: publicationIntent());
    fixture.journal.record = original;
    fixture.transport.lookup = (_) async {
      throw const ApiFailure(401, 'REAUTH_REQUIRED');
    };
    final controller = fixture.create(pending: original);
    addTearDown(controller.dispose);
    await controller.check();
    expect(
        controller.phase, PublicationViewPhase.queryReauthenticationRequired);
    expect(fixture.journal.record, original);
    expect(fixture.journal.marks, 0);
    expect(fixture.transport.posts, isEmpty);
  });

  test('a failed local preflight keeps a known not-submitted retry available',
      () async {
    final fixture = PublicationControllerFixture();
    final original = PublicationPending(
        intent: publicationIntent(),
        phase: PublicationPhase.reauthenticationRequired);
    fixture.journal.record = original;
    fixture.preflight = () async {
      throw const ApiFailure(503, 'SERVICE_UNAVAILABLE');
    };
    final controller = fixture.create(pending: original);
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    expect(controller.phase, PublicationViewPhase.retryableNotSubmitted);
    expect(controller.canConfirm, isTrue);
    expect(fixture.journal.claims, 0);
    expect(fixture.journal.record, original);
    expect(fixture.transport.posts, isEmpty);
  });

  test(
      'failed persistence of a trusted rejection cannot authorize another POST',
      () async {
    final fixture = PublicationControllerFixture();
    fixture.journal.markFailure = StateError('synthetic mark failure');
    fixture.transport.publish = (record) async {
      throw PublicationReauthenticationRequired(record);
    };
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    expect(controller.phase, PublicationViewPhase.storageBlocked);
    expect(controller.canConfirm, isFalse);
    expect(fixture.journal.record?.phase, PublicationPhase.unknown);
    await controller.submit();
    expect(fixture.transport.posts, hasLength(1));
    await controller.reloadPending();
    expect(controller.phase, PublicationViewPhase.unknown);
    expect(controller.canCheck, isTrue);
    expect(controller.canConfirm, isFalse);
    expect(fixture.transport.lookups, isEmpty);
  });

  test('storage failure blocks POST and explicit reload only reads locally',
      () async {
    final fixture = PublicationControllerFixture();
    fixture.journal.reserveFailure = StateError('synthetic storage failure');
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    expect(controller.phase, PublicationViewPhase.storageBlocked);
    expect(fixture.transport.posts, isEmpty);
    fixture.journal.reserveFailure = null;
    final original = PublicationPending(intent: publicationIntent());
    fixture.journal.record = original;
    await controller.reloadPending();
    expect(controller.phase, PublicationViewPhase.unknown);
    expect(controller.pending, original);
    expect(fixture.journal.reads, 1);
    expect(fixture.transport.lookups, isEmpty);
    expect(fixture.transport.posts, isEmpty);
  });

  test(
      'an unsafe old reauthentication proof cannot clear or restore a new slot',
      () async {
    final fixture = PublicationControllerFixture();
    fixture.transport.publish = (record) async {
      throw PublicationReauthenticationRequired(PublicationPending(
          intent: record.intent, attempt: record.attempt + 1));
    };
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    expect(controller.phase, PublicationViewPhase.unknown);
    expect(fixture.journal.marks, 0);
    expect(fixture.journal.record?.phase, PublicationPhase.unknown);
  });

  test('success and local cleanup failure remain separate facts', () async {
    final fixture = PublicationControllerFixture();
    fixture.journal.cleanupSucceeds = false;
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    expect(controller.phase, PublicationViewPhase.cleanupPending);
    expect(controller.receipt, isNotNull);
    expect(controller.canCheck, isTrue);
    expect(controller.canConfirm, isFalse);
    fixture.transport.lookup = (_) async => publicationReceipt();
    fixture.journal.cleanupSucceeds = true;
    await controller.check();
    expect(controller.phase, PublicationViewPhase.recorded);
    expect(fixture.transport.posts, hasLength(1));
    expect(fixture.transport.lookups, hasLength(1));
  });

  test('only a known not-submitted record can be explicitly cancelled',
      () async {
    final fixture = PublicationControllerFixture();
    final original = PublicationPending(
        intent: publicationIntent(expiresAt: publicationInstant - 1),
        phase: PublicationPhase.reauthenticationRequired);
    fixture.journal.record = original;
    final controller = fixture.create(pending: original);
    addTearDown(controller.dispose);
    expect(controller.canCancelNotSubmitted, isTrue);
    expect(await controller.cancelNotSubmitted(), isTrue);
    expect(fixture.journal.record, isNull);
    expect(fixture.transport.posts, isEmpty);
    expect(fixture.transport.lookups, isEmpty);
  });

  test('cleanup query authentication preserves the already confirmed receipt',
      () async {
    final fixture = PublicationControllerFixture();
    fixture.journal.cleanupSucceeds = false;
    final controller = fixture.create();
    addTearDown(controller.dispose);
    controller.beginConfirmation();
    await controller.submit();
    final confirmed = controller.receipt;
    fixture.transport.lookup = (_) async {
      throw const ApiFailure(401, 'REAUTH_REQUIRED');
    };
    await controller.check();
    expect(
        controller.phase, PublicationViewPhase.queryReauthenticationRequired);
    expect(controller.receipt, confirmed);
    expect(controller.canConfirm, isFalse);
    expect(fixture.journal.marks, 0);
    expect(fixture.transport.posts, hasLength(1));
  });
}
