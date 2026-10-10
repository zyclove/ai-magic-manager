import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'api.dart';
import 'device_diagnostic.dart';

const _knownErrors = {
  'REAUTH_REQUIRED',
  'SCOPE_DENIED',
  'DIAGNOSTIC_SCOPE_CHANGED',
  'DIAGNOSTIC_TOO_LARGE',
  'DIAGNOSTIC_SOURCE_INVALID',
  'DIAGNOSTIC_SERIALIZATION_FAILED',
  'AUTHENTICATION_REQUIRED'
};
final _identifier =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
Never _invalid() => throw const ApiFailure(502, 'INVALID_DIAGNOSTIC_RESPONSE');

class DiagnosticRepository {
  final Api api;
  final String tenantId, deviceId, registrationId;
  final bool Function() current;
  final Duration timeout;
  DiagnosticRepository(
      {required this.api,
      required this.tenantId,
      required this.deviceId,
      required this.registrationId,
      required this.current,
      this.timeout = const Duration(seconds: 25)});

  void _ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  void _cancel(Stream<List<int>> stream) {
    unawaited(stream.listen(null).cancel().catchError((Object _) {}));
  }

  Future<DeviceDiagnostic> load() async {
    _ensureCurrent();
    if (![tenantId, deviceId, registrationId].every(_identifier.hasMatch))
      _invalid();
    StreamSubscription<List<int>>? subscription;
    bool aborted = false, ended = false;
    try {
      return await (() async {
        final request = http.Request(
            'GET',
            Uri.parse(
                '${api.baseUrl}/tenants/$tenantId/devices/$deviceId/diagnostic-preview'))
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
        final client = await api.client();
        _ensureCurrent();
        if (aborted) throw const ApiFailure(0, 'NETWORK_ERROR');
        final response = await client.send(request);
        if (aborted || !current()) {
          _cancel(response.stream);
          _ensureCurrent();
          throw const ApiFailure(0, 'NETWORK_ERROR');
        }
        final maximum = response.statusCode == 200 ? 512 * 1024 : 65536;
        if (response.contentLength != null &&
            response.contentLength! > maximum) {
          _cancel(response.stream);
          _invalid();
        }
        final received = Completer<Uint8List>(),
            builder = BytesBuilder(copy: false);
        subscription = response.stream.listen((chunk) {
          if (received.isCompleted) return;
          if (builder.length + chunk.length > maximum) {
            received.completeError(
                const ApiFailure(502, 'INVALID_DIAGNOSTIC_RESPONSE'));
            return;
          }
          builder.add(chunk);
        }, onError: (Object error, StackTrace stack) {
          ended = true;
          if (!received.isCompleted) received.completeError(error, stack);
        }, onDone: () {
          ended = true;
          if (!received.isCompleted) received.complete(builder.takeBytes());
        }, cancelOnError: true);
        final bytes = await received.future;
        _ensureCurrent();
        dynamic value;
        try {
          value = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          value = null;
        }
        if (response.statusCode != 200) {
          final code = value is Json ? value['errorCode'] : null;
          final correlation = value is Json ? value['correlationId'] : null;
          throw ApiFailure(
              response.statusCode,
              code is String && _knownErrors.contains(code)
                  ? code
                  : 'REQUEST_FAILED',
              correlation is String && _identifier.hasMatch(correlation)
                  ? correlation
                  : null);
        }
        if (response.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase() !=
                'application/json' ||
            (response.contentLength != null &&
                response.contentLength != bytes.length)) _invalid();
        return DeviceDiagnostic.parse(value,
            tenantId: tenantId,
            deviceId: deviceId,
            registrationId: registrationId);
      })()
          .timeout(timeout);
    } on ApiFailure {
      rethrow;
    } catch (_) {
      _ensureCurrent();
      throw const ApiFailure(0, 'NETWORK_ERROR');
    } finally {
      aborted = true;
      if (!ended && subscription != null) {
        unawaited(subscription!.cancel().catchError((Object _) {}));
      }
    }
  }
}
