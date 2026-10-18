import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/policy_publication.dart';
import 'package:guardian/core/policy_publication_repository.dart';
import 'package:guardian/core/publication_journal.dart';
import 'package:guardian/ui/policy_publication_controller.dart';

// Supplemental controls authored before the controller implementation. They
// have not been run as RED; the separate six flow cases supply the actual RED.
const publicationInstant = 1792209600000;

PublicationOwner publicationOwner() => PublicationOwner(
    actorId: 'actor-a',
    tenantId: 'tenant-a',
    apiBaseUrl: 'https://fixture.invalid/api/v1',
    issuer: 'https://identity.fixture.invalid/realm');

PublicationIntent publicationIntent({String? key, int? expiresAt}) {
  final deadline = expiresAt ?? publicationInstant + 600000;
  return PublicationIntent(
      owner: publicationOwner(),
      policyId: 'policy-a',
      revision: 7,
      previewId: '11111111-1111-4111-8111-111111111111',
      previewHash: 'a' * 64,
      previewExpiresAt: deadline,
      createdAt: deadline <= publicationInstant
          ? deadline - 60000
          : publicationInstant,
      idempotencyKey: key ?? '22222222-2222-4222-8222-222222222222');
}

PublicationReceipt publicationReceipt() => PublicationReceipt.parse({
      'id': 'publication-a',
      'versionId': 'version-a',
      'sequence': 1,
      'mode': 'CONFIGURE_ONLY',
      'state': 'CONFIGURED_NOT_ENFORCED',
      'createdAt': publicationInstant,
    });

class PublicationTestAccess extends ChangeNotifier {
  bool current = true;

  void change(bool value) {
    current = value;
    notifyListeners();
  }

  void awayAndBack() {
    change(false);
    change(true);
  }
}

class PublicationTestJournal implements PublicationJournal {
  PublicationPending? record;
  Object? readFailure, reserveFailure, markFailure;
  bool cleanupSucceeds = true;
  int reads = 0, reserves = 0, claims = 0, marks = 0, removals = 0, cancels = 0;

  @override
  Future<PublicationPending?> read(
      PublicationOwner owner, String policyId) async {
    reads++;
    if (readFailure case final Object failure) throw failure;
    final stored = record;
    return stored?.intent.owner == owner && stored?.intent.policyId == policyId
        ? stored
        : null;
  }

  @override
  Future<PublicationReservation> reserve(PublicationIntent intent) async {
    reserves++;
    if (reserveFailure case final Object failure) throw failure;
    final stored = record;
    if (stored != null) {
      return PublicationReservation(record: stored, maySubmit: false);
    }
    final created = PublicationPending(intent: intent);
    record = created;
    return PublicationReservation(record: created, maySubmit: true);
  }

  @override
  Future<PublicationReservation> claimRetry(PublicationPending expected) async {
    claims++;
    final stored = record;
    if (stored == null) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    if (stored != expected ||
        stored.phase != PublicationPhase.reauthenticationRequired) {
      return PublicationReservation(record: stored, maySubmit: false);
    }
    final next =
        PublicationPending(intent: stored.intent, attempt: stored.attempt + 1);
    record = next;
    return PublicationReservation(record: next, maySubmit: true);
  }

  @override
  Future<PublicationPending> markReauthenticationRequired(
      PublicationPending expected) async {
    marks++;
    if (markFailure case final Object failure) throw failure;
    if (record != expected || expected.phase != PublicationPhase.unknown) {
      throw const ApiFailure(409, 'PUBLICATION_PENDING_CHANGED');
    }
    final next = PublicationPending(
        intent: expected.intent,
        phase: PublicationPhase.reauthenticationRequired,
        attempt: expected.attempt);
    record = next;
    return next;
  }

  @override
  Future<bool> removeIfSame(PublicationPending expected) async {
    removals++;
    if (!cleanupSucceeds || record != expected) return false;
    record = null;
    return true;
  }

  @override
  Future<bool> cancelNotSubmitted(PublicationPending expected) async {
    cancels++;
    if (expected.phase != PublicationPhase.reauthenticationRequired ||
        record != expected) return false;
    record = null;
    return true;
  }
}

class PublicationTestTransport {
  final posts = <PublicationPending>[];
  final lookups = <PublicationPending>[];
  Future<PublicationReceipt> Function(PublicationPending)? publish;
  Future<PublicationReceipt?> Function(PublicationPending)? lookup;
}

class PublicationTestRequests implements PublicationRequests {
  final PublicationTestTransport transport;
  final bool Function() permitted;
  final void Function(ApiFailure)? onDenied;

  PublicationTestRequests(this.transport,
      {bool Function()? permitted, this.onDenied})
      : permitted = permitted ?? (() => true);

  @override
  bool get isCurrent => permitted();

  @override
  PublicationRequests scoped(bool Function() current,
          {void Function(ApiFailure)? onDenied}) =>
      PublicationTestRequests(transport,
          permitted: () => isCurrent && current(),
          onDenied: (failure) {
            this.onDenied?.call(failure);
            onDenied?.call(failure);
          });

  void _requireCurrent() {
    if (!isCurrent) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  @override
  Future<PublicationReceipt> publish(PublicationPending record) async {
    _requireCurrent();
    transport.posts.add(record);
    final handler = transport.publish;
    return handler == null ? publicationReceipt() : await handler(record);
  }

  @override
  Future<PublicationReceipt?> lookup(PublicationPending record) async {
    _requireCurrent();
    transport.lookups.add(record);
    final handler = transport.lookup;
    return handler == null ? null : await handler(record);
  }
}

class PublicationControllerFixture {
  final access = PublicationTestAccess();
  final journal = PublicationTestJournal();
  final transport = PublicationTestTransport();
  DateTime now = DateTime.fromMillisecondsSinceEpoch(publicationInstant);
  int preflights = 0;
  Future<void> Function()? preflight;

  PolicyPublicationController create({PublicationPending? pending}) =>
      PolicyPublicationController(
          repository: PublicationTestRequests(transport),
          journal: journal,
          intent: pending?.intent ?? publicationIntent(),
          pending: pending,
          current: () => access.current,
          accessChanges: access,
          clock: () => now,
          preflight: () async {
            preflights++;
            await preflight?.call();
          });
}
