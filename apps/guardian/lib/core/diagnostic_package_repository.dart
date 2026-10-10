import 'dart:typed_data';
import 'api.dart';
import 'support.dart';
import 'support_repository.dart';
import 'diagnostic_package.dart';

class DiagnosticPackageDownload {
  final DiagnosticPackage job;
  final Uint8List bytes;
  DiagnosticPackageDownload(this.job, this.bytes);
}

class DiagnosticPackageRepository {
  final SupportRepository _transport;
  final bool received;
  final int Function() clock;
  DiagnosticPackageRepository(
      {required Api api,
      required String actor,
      String? tenant,
      required this.received,
      required bool Function() current,
      Duration timeout = const Duration(seconds: 25),
      int Function()? clock})
      : _transport = SupportRepository(
            api: api,
            actor: actor,
            tenant: tenant,
            current: current,
            timeout: timeout),
        clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  String get actor => _transport.actor;
  String? get tenant => _transport.tenant;
  String get mode => received ? 'SUPPORT_GRANT' : 'ADMIN';
  void ensureCurrent() => _transport.ensureCurrent();
  String get root => received
      ? '/support/diagnostic-packages'
      : '${_transport.customer}/diagnostic-packages';
  DiagnosticPackage parse(Object? input) => DiagnosticPackage.parse(input,
      actor: actor, mode: mode, tenant: received ? null : tenant);
  void _owned(DiagnosticPackage job) {
    ensureCurrent();
    if (job.requesterActorId != actor ||
        job.accessMode != mode ||
        (!received && job.tenantId != tenant))
      throw const ApiFailure(403, 'SCOPE_DENIED');
  }

  Future<DiagnosticPackage> create(DiagnosticPackageDraft draft) async {
    ensureCurrent();
    if (draft.mode != mode) throw const ApiFailure(403, 'SCOPE_DENIED');
    if (received &&
        (draft.grant!.recipientActorId != actor ||
            !draft.grant!.withinTerm(clock())))
      throw const ApiFailure(403, 'SCOPE_DENIED');
    final path = received
        ? '/support/grants/${supportId(draft.grantId)}/diagnostic-packages'
        : '${_transport.customer}/devices/${draft.deviceId}/diagnostic-packages';
    final job = parse(await _transport.request('POST', path,
        body: draft.body,
        key: draft.key,
        version: draft.deviceVersion,
        status: 202));
    draft.validateResult(job);
    return job;
  }

  Future<SupportPage<DiagnosticPackage>> list({String? cursor}) async =>
      SupportPage.parse(
          await _transport.request('GET', _transport.pagePath(root, cursor)),
          parse,
          (job) => job.id,
          after: cursor);
  Future<DiagnosticPackage> get(String id) async {
    final job =
        parse(await _transport.request('GET', '$root/${supportId(id)}'));
    if (job.id != id) invalidDiagnosticPackage();
    return job;
  }

  Future<DiagnosticPackage> cancel(DiagnosticPackage job, String key) async {
    _owned(job);
    supportText(key, 128);
    final current = parse(await _transport.request(
        'POST', '$root/${job.id}/cancel',
        key: key, version: job.version));
    job.validateUpdate(current);
    return current;
  }

  Future<DiagnosticPackageDownload> download(DiagnosticPackage expected) async {
    _owned(expected);
    final current = await get(expected.id);
    expected.validateUpdate(current);
    if (!current.readyAt(clock())) {
      if (current.stateAt(clock()) == 'EXPIRED')
        throw const ApiFailure(410, 'DIAGNOSTIC_PACKAGE_EXPIRED');
      if (current.state == 'REVOKED')
        throw const ApiFailure(403, 'SCOPE_DENIED');
      throw const ApiFailure(409, 'DIAGNOSTIC_PACKAGE_NOT_READY');
    }
    SupportGrant? grant;
    if (received) {
      grant = SupportGrant.parse(
          await _transport.request('GET', '/support/grants/${current.grantId}'),
          id: current.grantId,
          recipient: actor);
      validateDiagnosticPackageGrant(current, grant, clock());
    }
    final response = await _transport.request(
        'GET', '$root/${current.id}/content',
        maximum: 512 * 1024, rawBytes: true);
    ensureCurrent();
    if (response is! Uint8List) invalidDiagnosticPackage();
    final bytes = validateDiagnosticPackageDownload(response, current,
        grant: grant, now: clock());
    ensureCurrent();
    return DiagnosticPackageDownload(current, bytes);
  }
}
