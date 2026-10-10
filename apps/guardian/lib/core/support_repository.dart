import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api.dart';
import 'support.dart';
import 'support_diagnostic.dart';

const _errors = {
  'REAUTH_REQUIRED',
  'SCOPE_DENIED',
  'AUTHENTICATION_REQUIRED',
  'RESOURCE_VERSION_CONFLICT',
  'VERSION_REQUIRED',
  'SUPPORT_PAIRING_UNAVAILABLE',
  'SUPPORT_PAIRING_ALREADY_USED',
  'SUPPORT_PAIRING_CAPACITY_REACHED',
  'SUPPORT_PAIRING_RATE_LIMITED',
  'SUPPORT_GRANT_CAPACITY_REACHED',
  'SUPPORT_RECIPIENT_CHANGED',
  'SUPPORT_DEVICE_SCOPE_CHANGED',
  'INVALID_IDEMPOTENCY_KEY',
  'IDEMPOTENCY_KEY_REUSED',
  'VALIDATION_FAILED',
  'DIAGNOSTIC_TOO_LARGE',
  'DIAGNOSTIC_SOURCE_INVALID',
  'DIAGNOSTIC_SERIALIZATION_FAILED',
  'DIAGNOSTIC_PACKAGE_UNAVAILABLE',
  'DIAGNOSTIC_PACKAGE_NOT_READY',
  'DIAGNOSTIC_PACKAGE_EXPIRED',
  'DIAGNOSTIC_PACKAGE_CAPACITY_REACHED',
  'DIAGNOSTIC_PACKAGE_TEMPORARY_FAILURE',
  'DIAGNOSTIC_PACKAGE_ATTEMPTS_EXHAUSTED'
};

class SupportRepository {
  final Api api;
  final String actor;
  final String? tenant;
  final bool Function() current;
  final Duration timeout;
  SupportRepository(
      {required this.api,
      required this.actor,
      required this.current,
      this.tenant,
      this.timeout = const Duration(seconds: 25)});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  String get customer {
    ensureCurrent();
    return '/tenants/${supportId(tenant)}';
  }

  String pagePath(String path, String? cursor) {
    if (cursor != null) supportId(cursor);
    return '$path?limit=25${cursor == null ? '' : '&cursor=$cursor'}';
  }

  void cancel(Stream<List<int>> stream) {
    unawaited(stream.listen(null).cancel().catchError((Object _) {}));
  }

  Future<Object?> request(String method, String path,
      {Json? body,
      String? key,
      int? version,
      int status = 200,
      bool rawBytes = false,
      int maximum = 131072}) async {
    ensureCurrent();
    StreamSubscription<List<int>>? subscription;
    bool aborted = false, ended = false;
    try {
      return await (() async {
        final request = http.Request(method, Uri.parse('${api.baseUrl}$path'))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.body = jsonEncode(body);
        }
        if (key != null) request.headers['Idempotency-Key'] = key;
        if (version != null) request.headers['If-Match'] = '"$version"';
        final client = await api.client();
        ensureCurrent();
        if (aborted) throw const ApiFailure(0, 'NETWORK_ERROR');
        final response = await client.send(request);
        if (aborted || !current()) {
          cancel(response.stream);
          ensureCurrent();
          throw const ApiFailure(0, 'NETWORK_ERROR');
        }
        final limit = response.statusCode == status ? maximum : 65536;
        if (response.contentLength != null && response.contentLength! > limit) {
          cancel(response.stream);
          invalidSupport();
        }
        final bytes = BytesBuilder(copy: false),
            received = Completer<Uint8List>();
        subscription = response.stream.listen((chunk) {
          if (received.isCompleted) return;
          if (bytes.length + chunk.length > limit) {
            received.completeError(
                const ApiFailure(502, 'INVALID_SUPPORT_RESPONSE'));
            return;
          }
          bytes.add(chunk);
        }, onError: (Object e, StackTrace stack) {
          ended = true;
          if (!received.isCompleted) received.completeError(e, stack);
        }, onDone: () {
          ended = true;
          if (!received.isCompleted) received.complete(bytes.takeBytes());
        }, cancelOnError: true);
        final data = await received.future;
        ensureCurrent();
        Object? value;
        try {
          value = jsonDecode(utf8.decode(data));
        } on FormatException {
          value = null;
        }
        if (response.statusCode != status) {
          final code = value is Json ? value['errorCode'] : null,
              correlation = value is Json ? value['correlationId'] : null;
          throw ApiFailure(
              response.statusCode,
              code is String && _errors.contains(code)
                  ? code
                  : 'REQUEST_FAILED',
              correlation is String && supportIdentifier.hasMatch(correlation)
                  ? correlation
                  : null);
        }
        if (response.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase() !=
                'application/json' ||
            !(response.headers['cache-control'] ?? '')
                .toLowerCase()
                .split(',')
                .map((s) => s.trim())
                .contains('no-store') ||
            (response.contentLength != null &&
                response.contentLength != data.length)) invalidSupport();
        return rawBytes ? data : value;
      })()
          .timeout(timeout);
    } on ApiFailure {
      rethrow;
    } catch (_) {
      ensureCurrent();
      throw const ApiFailure(0, 'NETWORK_ERROR');
    } finally {
      aborted = true;
      if (!ended && subscription != null)
        unawaited(subscription!.cancel().catchError((Object _) {}));
    }
  }

  Future<CreatedSupportPairing> createPairing(String key) async =>
      CreatedSupportPairing.parse(
          await request('POST', '/support/pairing-requests',
              key: key, status: 201),
          actor);
  Future<SupportPage<SupportPairing>> pairings({String? cursor}) async =>
      SupportPage.parse(
          await request('GET', pagePath('/support/pairing-requests', cursor)),
          (v) => SupportPairing.parse(v, actor: actor),
          (v) => v.id,
          after: cursor);
  Future<SupportPairing> cancelPairing(
      SupportPairing pairing, String key) async {
    if (pairing.recipientActorId != actor) invalidSupport();
    return SupportPairing.parse(
        await request('POST', '/support/pairing-requests/${pairing.id}/cancel',
            key: key, version: pairing.version),
        actor: actor,
        id: pairing.id);
  }

  Future<SupportPairing> resolve(String code) async {
    if (!supportCode.hasMatch(code))
      throw const ApiFailure(400, 'INVALID_SUPPORT_SELECTION');
    return SupportPairing.parse(await request(
        'POST', '$customer/support-pairing/resolve',
        body: {'code': code}));
  }

  Future<SupportGrant> createGrant(SupportGrantDraft draft) async {
    if (draft.tenantId != tenant) invalidSupport();
    final grant = SupportGrant.parse(
        await request(
            'POST', '$customer/devices/${draft.deviceId}/support-grants',
            body: draft.body,
            key: draft.key,
            version: draft.deviceVersion,
            status: 201),
        tenant: tenant,
        recipient: draft.recipientActorId);
    if (grant.deviceId != draft.deviceId ||
        grant.registrationId != draft.registrationId ||
        grant.creatorActorId != actor ||
        grant.diagnosticTypes.join(',') != draft.diagnosticTypes.join(','))
      invalidSupport();
    return grant;
  }

  Future<SupportPage<SupportGrant>> grants(
          {required bool received, String? cursor}) async =>
      SupportPage.parse(
          await request(
              'GET',
              pagePath(
                  received ? '/support/grants' : '$customer/support-grants',
                  cursor)),
          (v) => SupportGrant.parse(v,
              tenant: received ? null : tenant,
              recipient: received ? actor : null),
          (v) => v.id,
          after: cursor);
  Future<SupportGrant> revoke(SupportGrant grant, String key) async {
    if (grant.tenantId != tenant) invalidSupport();
    return SupportGrant.parse(
        await request('POST', '$customer/support-grants/${grant.id}/revoke',
            key: key, version: grant.version),
        tenant: tenant,
        id: grant.id);
  }

  Future<SupportDiagnostic> diagnostic(SupportGrant grant) async {
    if (grant.recipientActorId != actor) invalidSupport();
    return SupportDiagnostic.parse(
        await request('GET', '/support/grants/${grant.id}/diagnostic-preview',
            maximum: 524288),
        grant);
  }
}
