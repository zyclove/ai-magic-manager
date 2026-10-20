// Actual production repository HTTP against an isolated Spring fixture.
// Adult JWT/MFA and runtime observations are test inputs; no supplier requests.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/family_identity_repository.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

void _require(bool value) {
  if (!value) throw StateError('Controlled release HTTP assertion failed.');
}

Future<void> _denied(Future<Object?> Function() action, int status) async {
  try {
    await action();
    throw StateError('Expected a rejected operation.');
  } on ApiFailure catch (failure) {
    _require(failure.status == status);
  }
}

class _TokenClient extends http.BaseClient {
  final http.Client delegate = http.Client();
  final String token;
  _TokenClient(this.token);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers['Authorization'] = 'Bearer $token';
    return delegate.send(request);
  }

  @override
  void close() => delegate.close();
}

class _DropCommittedReleaseReply extends http.BaseClient {
  final http.Client delegate;
  final String id;
  int posts = 0;
  bool committedReplyDropped = false;
  _DropCommittedReleaseReply(this.delegate, this.id);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    _require(request.method == 'POST' &&
        request.url.path.endsWith('/identity-providers/release-operations') &&
        request is http.Request &&
        (jsonDecode(request.body) as Json)['id'] == id);
    posts++;
    final response = await delegate.send(request);
    await response.stream.drain<void>();
    _require(response.statusCode == 200);
    committedReplyDropped = true;
    throw http.ClientException('Intentional isolated fixture reply loss.');
  }

  @override
  void close() {} // The main fixture owns the delegate.
}

String _proof(List<int> key, List<String> values) {
  final buffer = BytesBuilder(copy: false);
  for (final value in values) {
    final bytes = utf8.encode(value);
    buffer.add(ascii.encode('${bytes.length}:'));
    buffer.add(bytes);
  }
  return base64Url
      .encode(Hmac(sha256, key).convert(buffer.toBytes()).bytes)
      .replaceAll('=', '');
}

Future<void> main() async {
  final clients = <_TokenClient>[];
  final machineClient = http.Client();
  var checks = 0;
  try {
    String fixture(String suffix) {
      final value = Platform.environment['GUARDIAN_RELEASE_$suffix'];
      _require(value != null && value.isNotEmpty && value.length < 2048);
      return value!;
    }

    final base = Uri.parse(fixture('HTTP_BASE'));
    _require(base.scheme == 'http' &&
        base.host == '127.0.0.1' &&
        base.port > 1024 &&
        base.path == '/api/v1' &&
        base.userInfo.isEmpty &&
        !base.hasQuery &&
        !base.hasFragment);
    final environment = fixture('ENVIRONMENT');
    _require(environment == 'isolated-release-http');
    final encodedKey = fixture('EXECUTOR_KEY');
    _require(RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(encodedKey));
    final key = base64Url.decode('$encodedKey=');
    _require(key.length == 32 &&
        base64Url.encode(key).replaceAll('=', '') == encodedKey);
    FamilyIdentityRepository repository(String role) {
      final token = fixture('${role.toUpperCase()}_TOKEN');
      _require(RegExp('^release-$role-[0-9a-f-]{36}\$').hasMatch(token));
      final client = _TokenClient(token);
      clients.add(client);
      return FamilyIdentityRepository(
          api: Api(() async => client, baseUrl: base.toString()),
          current: () => true);
    }

    final admin = repository('admin'), publisher = repository('publisher');
    final rollback = repository('rollback'), weak = repository('weak');
    final reader = repository('reader');
    String id() => const Uuid().v4();
    Future<Json> machine(String action, String operation, String claim) async {
      // UUID entropy supplies fresh fixture nonces without any reusable proof.
      final random = sha256.convert(utf8.encode('${id()}${id()}')).bytes;
      final actualNonce = base64Url.encode(random).replaceAll('=', '');
      final issuedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final path = switch (action) {
        'CLAIM' => '',
        'BEGIN' => '/begin',
        'QUERY' => '/query',
        _ => throw StateError('Unknown isolated machine action.')
      };
      final body = <String, Object>{
        'environmentId': environment,
        'operationId': operation,
        'claimId': claim,
        'nonce': actualNonce,
        'issuedAt': issuedAt,
        'proof': _proof(key, [
          'family-identity-executor-request-v1',
          action,
          environment,
          operation,
          claim,
          actualNonce,
          '$issuedAt',
          ''
        ])
      };
      final response = await machineClient
          .post(
              Uri.parse(
                  '$base/platform/identity-provider-executor/claims$path'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(body))
          .timeout(const Duration(seconds: 15));
      _require(response.statusCode == 200);
      final result = jsonDecode(response.body) as Json;
      _require(result['operationId'] == operation &&
          result['claimId'] == claim &&
          result['environmentId'] == environment &&
          result['executionAllowed'] is bool);
      return result;
    }

    final initial = await admin.releaseStatus();
    _require(initial.runtimeRevision == 0 &&
        initial.activeOperation == null &&
        initial.confirmedOperation == null &&
        initial.observationReady &&
        initial.executorReady);
    checks++;
    await _denied(weak.releaseStatus, 401);
    checks++;
    final initialAcceptance = await admin.acceptanceStatus();
    _require(initialAcceptance.versionId == null &&
        initialAcceptance.nextAction == 'CONFIGURE' &&
        initialAcceptance.passedCount == 0 &&
        initialAcceptance.requiredCount == 12 &&
        initialAcceptance.salesChecks.length == 5);
    checks++;
    await _denied(weak.acceptanceStatus, 401);
    checks++;
    await _denied(weak.acceptanceRuns, 401);
    checks++;
    _require((await reader.acceptanceStatus()).nextAction == 'CONFIGURE');
    checks++;
    const settings = IdentityProviderSettings(
        smsSignName: '家庭服务',
        smsTemplateCode: 'SMS_123456',
        wechatAppId: 'wx0123456789abcdef',
        parentPackageName: 'com.aimanager.parent',
        parentCertificateSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    final version1 = await admin.saveVersion(id(), 0, settings, replacements: {
      'smsAccessKeyId': 'LTAIReleaseFixture123456',
      'smsAccessKeySecret': 'ReleaseFixtureSecret123456789',
      'wechatAppSecret': 'abcdef0123456789abcdef0123456789'
    });
    _require(version1.version == 1);
    checks++;
    final prepared1 = await admin.prepareRelease(id(), version1.id);
    _require(prepared1.status == 'PREPARED');
    checks++;
    final listed1 = await publisher.releasePreparations(version1.id);
    _require(
        listed1.any((p) => p.id == prepared1.id && p.status == 'PREPARED'));
    checks++;
    await _denied(() => weak.releasePreparations(version1.id), 401);
    checks++;
    await _denied(() => publisher.prepareRelease(id(), version1.id), 403);
    checks++;
    final jar = 'a' * 64, apk = 'b' * 64, lostId = id();
    final dropped = _DropCommittedReleaseReply(clients[1], lostId);
    final losing = FamilyIdentityRepository(
        api: Api(() async => dropped, baseUrl: base.toString()),
        current: () => true);
    await _denied(
        () => losing.requestRelease(
            lostId, 'PUBLISH', version1.id, prepared1.id, 0, jar, apk),
        0);
    _require(dropped.committedReplyDropped && dropped.posts == 1);
    checks++;
    final original = await publisher.releaseOperation(lostId);
    _require(original.state == 'WAITING_EXECUTOR' &&
        original.versionId == version1.id);
    checks++;
    final pending = await admin.releaseStatus();
    _require(pending.activeOperation?.id == lostId &&
        pending.runtimeRevision == 1 &&
        dropped.posts == 1);
    checks++;
    await _denied(
        () => admin.requestRelease(id(), 'PUBLISH', version1.id, prepared1.id,
            pending.runtimeRevision, jar, apk),
        409);
    checks++;
    await _denied(
        () => weak.requestRelease(id(), 'PUBLISH', version1.id, prepared1.id,
            pending.runtimeRevision, jar, apk),
        401);
    checks++;
    final cancelId = id();
    _require((await publisher.cancelRelease(
                cancelId, lostId, pending.runtimeRevision))
            .state ==
        'CANCELLED');
    checks++;
    _require((await publisher.cancellation(cancelId)).id == lostId);
    checks++;
    final afterCancel = await admin.releaseStatus();
    _require(afterCancel.activeOperation == null);
    checks++;
    final first = await publisher.requestRelease(id(), 'PUBLISH', version1.id,
        prepared1.id, afterCancel.runtimeRevision, jar, apk);
    _require(first.state == 'WAITING_EXECUTOR');
    checks++;
    final claim1 = id(), claimed1 = await machine('CLAIM', first.id, claim1);
    _require(claimed1['state'] == 'CLAIMED' &&
        claimed1['executionAllowed'] == false);
    checks++;
    await _denied(() => admin.checkRuntime(id(), first.id), 409);
    checks++;
    _require(
        (await machine('BEGIN', first.id, claim1))['executionAllowed'] == true);
    checks++;
    _require((await machine('BEGIN', first.id, claim1))['executionAllowed'] ==
        false);
    checks++;
    _require((await machine('QUERY', first.id, claim1))['state'] ==
        'EXECUTION_UNKNOWN');
    checks++;
    final check1 = await admin.checkRuntime(id(), first.id);
    _require(check1.state == 'CONFIRMED' &&
        check1.instances.every((i) => i.state == 'CONFIRMED'));
    checks++;
    _require((await admin.runtimeCheck(check1.id)).state == 'CONFIRMED');
    checks++;
    _require(
        (await publisher.releaseOperation(first.id)).state == 'APPLIED_CLOSED');
    checks++;
    final status1 = await admin.releaseStatus();
    _require(status1.activeOperation == null &&
        status1.confirmedOperation?.versionId == version1.id);
    checks++;
    _require(
        (await machine('QUERY', first.id, claim1))['canFinalizeHostPointer'] ==
            true);
    checks++;
    final readyAcceptance = await admin.acceptanceStatus();
    _require(readyAcceptance.environmentId == environment &&
        readyAcceptance.versionId == version1.id &&
        readyAcceptance.confirmedOperationId == first.id &&
        readyAcceptance.runtimeRevision == status1.runtimeRevision &&
        readyAcceptance.nextAction == 'REGISTER_RUN' &&
        readyAcceptance.passedCount == 0 &&
        readyAcceptance.checks.every((check) => check.status == 'PENDING'));
    checks++;
    _require((await admin.acceptanceRuns()).isEmpty);
    checks++;
    final acceptanceId = id();
    final boundRun = await admin.startAcceptance(
        acceptanceId, version1.id, environment, jar, apk,
        releaseOperationId: first.id,
        expectedRuntimeRevision: status1.runtimeRevision);
    _require(boundRun.releaseOperationId == first.id &&
        boundRun.runtimeRevision == status1.runtimeRevision &&
        boundRun.expiresAt == boundRun.createdAt + 86400000 &&
        boundRun.checks.every((check) => check.status != 'READY'));
    checks++;
    final replay = await admin.startAcceptance(
        acceptanceId, version1.id, environment, jar, apk,
        releaseOperationId: first.id,
        expectedRuntimeRevision: status1.runtimeRevision);
    _require(
        replay.id == boundRun.id && replay.expiresAt == boundRun.expiresAt);
    checks++;
    _require((await admin.acceptanceRun(acceptanceId)).releaseOperationId ==
        first.id);
    checks++;
    final pendingAcceptance = await admin.acceptanceStatus();
    _require(pendingAcceptance.status == 'PENDING' &&
        pendingAcceptance.nextAction == 'PREPARE_PILOT' &&
        pendingAcceptance.latestRun?.id == acceptanceId &&
        pendingAcceptance.passedCount == 0 &&
        pendingAcceptance.salesChecks
            .any((check) => check.status == 'BLOCKED'));
    checks++;
    _require((await reader.acceptanceRuns()).single.id == acceptanceId);
    checks++;
    await _denied(
        () => reader.startAcceptance(id(), version1.id, environment, jar, apk,
            releaseOperationId: first.id,
            expectedRuntimeRevision: status1.runtimeRevision),
        403);
    checks++;
    await _denied(
        () => admin.startAcceptance(
            id(), version1.id, environment, 'c' * 64, apk,
            releaseOperationId: first.id,
            expectedRuntimeRevision: status1.runtimeRevision),
        409);
    checks++;
    await _denied(
        () => admin.startAcceptance(
            acceptanceId, version1.id, environment, jar, apk,
            releaseOperationId: first.id,
            expectedRuntimeRevision: status1.runtimeRevision + 1),
        409);
    checks++;
    final version2 = await admin.saveVersion(id(), 1, settings, replacements: {
      'smsAccessKeySecret': 'ReleaseFixtureRotatedSecret123456789'
    });
    final prepared2 = await admin.prepareRelease(id(), version2.id);
    _require(prepared2.status == 'PREPARED' &&
        (await publisher.releasePreparations(version2.id)).first.id ==
            prepared2.id);
    checks++;
    final changedAcceptance = await admin.acceptanceStatus();
    _require(changedAcceptance.status == 'STALE' &&
        changedAcceptance.nextAction == 'PUBLISH_CONFIGURATION' &&
        changedAcceptance.latestRun?.id == acceptanceId &&
        changedAcceptance.passedCount == 0);
    checks++;
    final historicalReplay = await admin.startAcceptance(
        acceptanceId, version1.id, environment, jar, apk,
        releaseOperationId: first.id,
        expectedRuntimeRevision: status1.runtimeRevision);
    _require(historicalReplay.runtimeRevision == boundRun.runtimeRevision &&
        historicalReplay.expiresAt == boundRun.expiresAt);
    checks++;
    final second = await publisher.requestRelease(id(), 'PUBLISH', version2.id,
        prepared2.id, status1.runtimeRevision, jar, apk);
    _require((await admin.releaseStatus()).runtimeStatus == 'APPLY_REQUIRED');
    checks++;
    final applyingAcceptance = await admin.acceptanceStatus();
    _require(applyingAcceptance.status == 'STALE' &&
        applyingAcceptance.nextAction == 'CHECK_RUNTIME');
    checks++;
    _require(
        (await machine('QUERY', first.id, claim1))['canFinalizeHostPointer'] ==
            false);
    checks++;
    final claim2 = id();
    await machine('CLAIM', second.id, claim2);
    _require((await machine('BEGIN', second.id, claim2))['executionAllowed'] ==
        true);
    checks++;
    _require((await admin.checkRuntime(id(), second.id)).state == 'CONFIRMED');
    checks++;
    final status2 = await admin.releaseStatus();
    _require(
        (await machine('QUERY', first.id, claim1))['canFinalizeHostPointer'] ==
            false);
    checks++;
    final target =
        status2.rollbackTargets.singleWhere((t) => t.versionId == version1.id);
    _require(target.preparationId == prepared1.id &&
        target.providerJarSha256 == jar);
    checks++;
    await _denied(
        () => publisher.requestRelease(id(), 'ROLLBACK', target.versionId,
            target.preparationId, status2.runtimeRevision, jar, apk),
        403);
    checks++;
    await _denied(
        () => rollback.requestRelease(id(), 'PUBLISH', version2.id,
            prepared2.id, status2.runtimeRevision, jar, apk),
        403);
    checks++;
    final restored = await rollback.requestRelease(
        id(),
        'ROLLBACK',
        target.versionId,
        target.preparationId,
        status2.runtimeRevision,
        target.providerJarSha256,
        target.parentApkSha256);
    _require(
        restored.kind == 'ROLLBACK' && restored.state == 'WAITING_EXECUTOR');
    checks++;
    final claim3 = id();
    await machine('CLAIM', restored.id, claim3);
    _require(
        (await machine('BEGIN', restored.id, claim3))['executionAllowed'] ==
            true);
    checks++;
    _require(
        (await rollback.checkRuntime(id(), restored.id)).state == 'CONFIRMED');
    checks++;
    final finalStatus = await admin.releaseStatus();
    _require(finalStatus.activeOperation == null &&
        finalStatus.confirmedOperation?.versionId == version1.id &&
        finalStatus.runtimeStatus == 'APPLIED_CLOSED');
    checks++;
    final rolledBackAcceptance = await admin.acceptanceStatus();
    _require(rolledBackAcceptance.status == 'STALE' &&
        rolledBackAcceptance.nextAction == 'PUBLISH_CONFIGURATION' &&
        rolledBackAcceptance.passedCount == 0 &&
        rolledBackAcceptance.salesChecks
            .any((check) => check.status == 'BLOCKED'));
    checks++;
    final run =
        await admin.startAcceptance(id(), version1.id, environment, jar, apk);
    _require(run.checks.length == 12 &&
        run.checks.every((c) => c.status != 'READY') &&
        run.releaseOperationId == null &&
        run.runtimeRevision == null &&
        run.expiresAt == null);
    checks++;
    final history = await admin.acceptanceRuns();
    _require(history.length <= 5 &&
        history.any((item) => item.id == run.id) &&
        history.any((item) => item.id == acceptanceId));
    checks++;
    final forbidden = await clients.first.post(
        Uri.parse(
            '$base/platform/identity-providers/acceptance-runs/${run.id}/checks/REAL_SMS_DELIVERY'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'status': 'PASS'}));
    _require(forbidden.statusCode == 404 && dropped.posts == 1);
    checks++;
    stdout.writeln('Controlled release production HTTP checks passed: $checks');
  } catch (_) {
    stderr.writeln(
        'Controlled release production HTTP check failed after $checks completed checks.');
    exitCode = 1;
  } finally {
    machineClient.close();
    for (final client in clients) {
      client.close();
    }
  }
}
