import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:usage_reporting/usage_reporting.dart';
import 'api.dart';
export 'package:usage_reporting/usage_reporting.dart'
    show
        usageReportRoles,
        usageLocation,
        usageLocalTime,
        usageTimestamp,
        usageCalendarWindow,
        UsageReportTarget,
        UsageReportScope,
        UsageReportQuery,
        UsageReportBucket,
        UsageReportApplication,
        UsageReportDevice,
        UsageReport,
        usageRange,
        UsageReportFailure;

const _limit = 8 * 1024 * 1024;
Never _invalid() =>
    throw const ApiFailure(502, 'INVALID_USAGE_REPORT_RESPONSE');

class UsageReportRepository {
  final Api api;
  final String root;
  final bool Function() current;
  UsageReportRepository(
      {required this.api, required this.root, required this.current});
  void ensureCurrent() {
    if (!current()) throw const ApiFailure(409, 'WORKSPACE_CHANGED');
  }

  Future<UsageReport> load(UsageReportQuery query) async {
    ensureCurrent();
    StreamSubscription<List<int>>? subscription;
    bool ended = false, aborted = false;
    try {
      return await (() async {
        final request =
            http.Request('GET', Uri.parse('${api.baseUrl}$root${query.path}'))
              ..followRedirects = false
              ..headers['Accept'] = 'application/json';
        final client = await api.client();
        ensureCurrent();
        if (aborted) throw const ApiFailure(0, 'NETWORK_ERROR');
        final response = await client.send(request);
        if (aborted || !current()) {
          unawaited(
              response.stream.listen(null).cancel().catchError((Object _) {}));
          ensureCurrent();
          throw const ApiFailure(0, 'NETWORK_ERROR');
        }
        final max = response.statusCode == 200 ? _limit : 65536;
        if (response.contentLength != null && response.contentLength! > max) {
          unawaited(
              response.stream.listen(null).cancel().catchError((Object _) {}));
          _invalid();
        }
        final received = Completer<Uint8List>(),
            builder = BytesBuilder(copy: false);
        subscription = response.stream.listen((chunk) {
          if (received.isCompleted) return;
          if (builder.length + chunk.length > max) {
            received.completeError(
                const ApiFailure(502, 'INVALID_USAGE_REPORT_RESPONSE'));
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
        ensureCurrent();
        dynamic value;
        try {
          value = jsonDecode(utf8.decode(bytes));
        } on FormatException {
          value = null;
        }
        if (response.statusCode != 200) {
          throw ApiFailure(
              response.statusCode,
              value is Json && value['errorCode'] is String
                  ? value['errorCode']
                  : 'REQUEST_FAILED',
              value is Json && value['correlationId'] is String
                  ? value['correlationId']
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
        return UsageReport.parse(value, query);
      })()
          .timeout(const Duration(seconds: 25));
    } on UsageReportFailure catch (error) {
      throw ApiFailure(error.status, error.code);
    } on TimeoutException {
      ensureCurrent();
      throw const ApiFailure(0, 'NETWORK_ERROR');
    } on http.ClientException {
      ensureCurrent();
      throw const ApiFailure(0, 'NETWORK_ERROR');
    } finally {
      aborted = true;
      if (!ended && subscription != null) {
        unawaited(subscription!.cancel().catchError((Object _) {}));
      }
    }
  }
}
