import 'dart:convert';
import 'dart:io';
import 'package:device_access/device_access.dart';
import 'package:sembast/sembast_io.dart';

void require(bool condition) {
  if (!condition) {
    throw StateError('Access HTTP interoperability assertion failed');
  }
}

Future<void> main(List<String> arguments) async {
  const modes = {
    'context',
    'context-denied',
    'missing',
    'recover-unconfirmed',
    'resume',
    'revoked',
    'expired',
    'unauthenticated'
  };
  if (arguments.length != 2 || !modes.contains(arguments[1])) {
    throw ArgumentError('Provide fixture and mode');
  }
  final file = File(arguments[0]);
  final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final apiRoot = Uri.parse(data['apiRoot']);
  if (apiRoot.scheme != 'http' || apiRoot.host != '127.0.0.1') {
    throw ArgumentError('Loopback test fixture required');
  }
  final mode = arguments[1];
  final grants = (data['grants'] as List).cast<Map<String, dynamic>>();
  if (mode == 'context' || mode == 'context-denied') {
    final transport = DeviceAccessTransport(
        apiRoot: apiRoot,
        credential: () async => data['credential'],
        allowLoopbackHttp: true);
    try {
      if (mode == 'context') {
        final context = await transport.context();
        context.requireIdentity(
            tenantId: data['tenantId'],
            deviceId: data['deviceId'],
            registrationId: data['registrationId']);
        require(context.subjectId == data['subjectId']);
      } else {
        var denied = false;
        try {
          await transport.context();
        } on AccessTransportFailure catch (error) {
          denied =
              error.status == 401 && error.code == 'DEVICE_UNAUTHENTICATED';
        }
        require(denied);
      }
      stdout.writeln(
          'PASS $mode: authenticated Spring/Dart context; no cached or caller-selected binding.');
    } finally {
      transport.close();
    }
    return;
  }
  final database = await databaseFactoryIo
      .openDatabase('${file.parent.path}/access-cache.db');
  final verifier = AccessWindowVerifier(
      scope: DeviceAccessScope(
          issuer: 'ai-manager',
          tenantId: data['tenantId'],
          subjectId: data['subjectId'],
          deviceId: data['deviceId'],
          registrationId: data['registrationId']),
      trustedKeys: data['publicKeys'],
      nowMillis: () => data['nowMillis']);
  final journal = AccessWindowJournal(
      database: database,
      verifier: verifier,
      baselineMatches: (value) =>
          mode != 'missing' &&
          grants.any((g) =>
              value.policyId == g['policyId'] &&
              value.baseVersionId == g['baseVersionId'] &&
              value.applicationId == g['applicationId'] &&
              value.ruleIds.length == 1 &&
              value.ruleIds.single == 'game'));
  final transport = DeviceAccessTransport(
      apiRoot: apiRoot,
      credential: () async => data['credential'],
      allowLoopbackHttp: true);
  final sync = DeviceAccessSynchronizer(
      journal: journal, transport: transport, pageSize: 1, maxPages: 5);
  try {
    if (mode == 'unauthenticated') {
      var denied = false;
      try {
        await sync.synchronize();
      } on AccessTransportFailure catch (error) {
        denied = error.status == 401 &&
            error.code == 'DEVICE_UNAUTHENTICATED' &&
            !error.retryable;
      }
      require(denied && (await journal.restore()).isEmpty);
    } else {
      final result = await sync.synchronize();
      require(result.pages == 2 && !result.hasMore && !result.systemEnforced);
      if (mode == 'missing') {
        require(result.issues.length == 2 &&
            result.issues.every((i) => i.code == 'BASELINE_MISSING'));
        require((await journal.restore()).isEmpty &&
            (await journal.pendingReceipts()).isEmpty);
      } else {
        require(
            result.issues.isEmpty && (await journal.pendingReceipts()).isEmpty);
        final active = await journal.restore();
        require(active.length ==
            (mode == 'revoked'
                ? 1
                : mode == 'expired'
                    ? 0
                    : 2));
        for (final value in active.values) {
          require(value.absoluteNotAfter ==
              grants.singleWhere((g) => g['requestId'] == value.requestId)[
                  'absoluteNotAfter']);
        }
        if (mode == 'recover-unconfirmed') {
          require(result.retriesCreated == 2);
          final document = await transport.document(grants.first['requestId']);
          require(document.deliveryAttempt == 2);
          final receipt = await journal.accept(document);
          await transport.acknowledge(receipt);
          // Simulate process loss AFTER server ACK, BEFORE local queue deletion.
          require((await journal.pendingReceipts()).length == 1);
          await File('${file.parent.path}/original-approved.json')
              .writeAsString(jsonEncode({
            'requestId': document.requestId,
            'documentId': document.documentId,
            'approvalVersion': document.approvalVersion,
            'action': document.action,
            'signedDocument': document.signedDocument,
            'documentIssuedAt': document.documentIssuedAt,
            'deliveryAttempt': document.deliveryAttempt,
            'deliveryState': document.deliveryState,
            'retryStatus': document.retryStatus
          }));
        }
        if (mode == 'revoked' || mode == 'expired') {
          final original = AccessDocument.fromJson(jsonDecode(
              await File('${file.parent.path}/original-approved.json')
                  .readAsString()));
          var stale = false;
          try {
            await journal.accept(original);
          } on AccessFailure catch (error) {
            stale = error.code == 'STALE_APPROVAL';
          }
          require(stale);
        }
      }
    }
    stdout.writeln(
        'PASS $mode: real Spring HTTP, opaque credentials, Nimbus and durable Dart receipts; CONFIGURE_ONLY.');
  } finally {
    sync.close();
    await database.close();
  }
}
