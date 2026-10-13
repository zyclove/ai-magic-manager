import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:usage_reporting/usage_reporting.dart';
import 'parent_api.dart';

/// Owns only its report connection. Cancellation never closes the shared session client.
class ParentUsageReportLoader {
  final ParentApi api;
  final String tenant;
  final Future<String> Function() token;
  final bool Function() available;
  final http.Client Function() clientFactory;
  http.Client? _active;
  void Function()? _abort;
  int _generation = 0;
  ParentUsageReportLoader(
      {required this.api,
      required this.tenant,
      required this.token,
      required this.available,
      http.Client Function()? clientFactory})
      : clientFactory = clientFactory ?? http.Client.new;
  void cancel() {
    _generation++;
    _abort?.call();
    _abort = null;
    _active?.close();
    _active = null;
  }

  Future<UsageReport> load(UsageReportQuery query) async {
    cancel();
    final generation = _generation;
    void check() {
      if (generation != _generation || !available()) {
        throw const UsageReportFailure(409, 'REPORT_SCOPE_CHANGED');
      }
    }

    http.Client? client;
    StreamSubscription<List<int>>? subscription;
    void Function()? abort;
    try {
      return await (() async {
        check();
        // A fresh registration check prevents an old page reading a re-enrolled device.
        Future<void> verifyTarget(UsageReportTarget target) async {
          final device = await api.object(
              '/tenants/$tenant/devices/${target.deviceId}',
              isCurrent: () => generation == _generation && available());
          check();
          if (device['id'] != target.deviceId ||
              device['registrationId'] != target.registrationId ||
              device['subjectId'] != target.subjectId ||
              device['platform'] != target.platform ||
              device['state'] != 'ACTIVE') {
            throw const UsageReportFailure(409, 'REPORT_SCOPE_CHANGED');
          }
        }

        // At most four independent directory reads; every selected registration
        // must pass before opening the report connection. Never truncate a set.
        for (var offset = 0; offset < query.targets.length; offset += 4) {
          check();
          await Future.wait(
              query.targets.skip(offset).take(4).map(verifyTarget),
              eagerError: true);
        }
        final accessToken = await token();
        check();
        client = clientFactory();
        _active = client;
        final request = http.Request(
            'GET', Uri.parse('${api.baseUrl}/tenants/$tenant${query.path}'))
          ..followRedirects = false
          ..headers.addAll({
            'Accept': 'application/json',
            'Authorization': 'Bearer $accessToken',
            'Cache-Control': 'no-store'
          });
        final response = await client!.send(request);
        check();
        final maximum = response.statusCode == 200 ? 8 * 1024 * 1024 : 65536;
        if (response.contentLength != null &&
            response.contentLength! > maximum) {
          throw const UsageReportFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
        }
        final bytes = BytesBuilder(copy: false),
            received = Completer<Uint8List>();
        abort = () {
          if (!received.isCompleted) {
            received.completeError(
                const UsageReportFailure(409, 'REPORT_SCOPE_CHANGED'));
          }
        };
        _abort = abort;
        subscription = response.stream.listen((chunk) {
          if (received.isCompleted) return;
          if (bytes.length + chunk.length > maximum) {
            received.completeError(
                const UsageReportFailure(502, 'INVALID_USAGE_REPORT_RESPONSE'));
            return;
          }
          bytes.add(chunk);
        }, onError: (Object e, StackTrace stack) {
          if (!received.isCompleted) received.completeError(e, stack);
        }, onDone: () {
          if (!received.isCompleted) received.complete(bytes.takeBytes());
        }, cancelOnError: true);
        final body = await received.future;
        check();
        dynamic data;
        try {
          data = jsonDecode(utf8.decode(body));
        } on FormatException {
          throw const UsageReportFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
        }
        if (response.statusCode != 200) {
          throw UsageReportFailure(
              response.statusCode,
              data is Json && data['errorCode'] is String
                  ? data['errorCode']
                  : 'REQUEST_FAILED');
        }
        if (response.headers['content-type']
                    ?.split(';')
                    .first
                    .trim()
                    .toLowerCase() !=
                'application/json' ||
            response.contentLength != null &&
                response.contentLength != body.length) {
          throw const UsageReportFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');
        }
        return UsageReport.parse(data, query);
      })()
          .timeout(const Duration(seconds: 25));
    } on ParentApiException catch (e) {
      throw UsageReportFailure(e.status, e.code);
    } on TimeoutException {
      throw const UsageReportFailure(0, 'NETWORK_ERROR');
    } on http.ClientException {
      check();
      throw const UsageReportFailure(0, 'NETWORK_ERROR');
    } finally {
      // Invalidate token/device reads still waiting when the timeout fires.
      if (generation == _generation) _generation++;
      if (identical(_abort, abort)) _abort = null;
      if (subscription != null) {
        unawaited(subscription!.cancel().catchError((Object _) {}));
      }
      if (identical(_active, client)) _active = null;
      client?.close();
    }
  }
}
