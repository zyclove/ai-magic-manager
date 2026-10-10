import 'package:device_access/device_access.dart' as access;
import 'package:device_identity/device_identity.dart';
import 'package:device_observation/device_observation.dart' as observation;
import 'package:device_policy/device_policy.dart';
import 'package:device_reports/device_reports.dart';
import 'package:http/http.dart' as http;
import 'package:usage_report_ui/usage_report_ui.dart';
import 'session.dart';

abstract interface class ChildReports {
  Future<UsageReport> load(DeviceReportWindow window);
  void cancel();
  void close();
}

typedef ChildReportFactory = ChildReports Function(ChildSession session);

/// Resolves an authenticated subject on every read; no adult credentials,
/// retained private report, browser registration or UI supplied identity.
class DeviceChildReports implements ChildReports {
  final ChildSession session;
  final Uri apiRoot;
  final bool allowLoopbackHttp;
  final Future<observation.ObservationPlatformState> Function() inspect;
  final http.Client Function()? contextClient, reportClient;
  final Set<void Function()> _closers = {};
  int _epoch = 0;
  bool _closed = false;
  DeviceChildReports(
      {required this.session,
      required this.apiRoot,
      required this.inspect,
      this.allowLoopbackHttp = false,
      this.contextClient,
      this.reportClient});

  bool _current(int epoch, DeviceIdentityView? identity) {
    final current = session.identityView;
    return !_closed &&
        epoch == _epoch &&
        session.foreground &&
        session.identityReadSucceeded &&
        session.credentialReady &&
        identity != null &&
        identity.deviceId != null &&
        identity.registrationId != null &&
        current != null &&
        !current.cloudAuthenticationBlocked &&
        current.tenantId == identity.tenantId &&
        current.deviceId == identity.deviceId &&
        current.registrationId == identity.registrationId;
  }

  void _check(int epoch, DeviceIdentityView? identity) {
    if (!_current(epoch, identity)) {
      throw const UsageReportFailure(409, 'DEVICE_CONTEXT_CHANGED');
    }
  }

  @override
  Future<UsageReport> load(DeviceReportWindow window) async {
    cancel();
    final epoch = _epoch, identity = session.identityView;
    _check(epoch, identity);
    final closers = <void Function()>[];
    void own(void Function() close) {
      closers.add(close);
      _closers.add(close);
    }

    Future<String?> credential() async {
      _check(epoch, identity);
      final value = await session.identity.activeCredential();
      _check(epoch, identity);
      return value;
    }

    try {
      final platform = await inspect();
      _check(epoch, identity);
      if (!platform.unlocked) {
        throw const UsageReportFailure(403, 'DEVICE_LOCKED');
      }
      final binding = access.DeviceAccessTransport(
          apiRoot: apiRoot,
          credential: credential,
          allowLoopbackHttp: allowLoopbackHttp,
          client: contextClient?.call());
      own(binding.close);
      final context = await binding.context();
      _check(epoch, identity);
      context.requireIdentity(
          tenantId: identity!.tenantId,
          deviceId: identity.deviceId!,
          registrationId: identity.registrationId!);
      final transport = DeviceConfigurationTransport(
          apiRoot: apiRoot,
          credential: credential,
          allowLoopbackHttp: allowLoopbackHttp,
          client: reportClient?.call());
      own(transport.close);
      final reader = DeviceUsageReportClient(
          transport: transport,
          target: UsageReportTarget(context.deviceId, context.registrationId,
              context.subjectId, '本设备',
              platform: platform.television ? 'ANDROID_TV' : 'ANDROID'),
          current: () => _current(epoch, identity));
      own(reader.dispose);
      final report = await reader.load(
          from: window.from,
          to: window.to,
          timeZone: window.timeZone,
          period: window.period);
      _check(epoch, identity);
      return report;
    } on DeviceTransportFailure catch (e) {
      _check(epoch, identity);
      throw _failure(e.status, e.code);
    } on access.AccessTransportFailure catch (e) {
      _check(epoch, identity);
      throw _failure(e.status, e.code);
    } on access.AccessFailure catch (e) {
      _check(epoch, identity);
      throw UsageReportFailure(409, e.code);
    } on DeviceIdentityFailure {
      _check(epoch, identity);
      throw const UsageReportFailure(401, 'DEVICE_CREDENTIAL_UNAVAILABLE');
    } on observation.ObservationFailure catch (e) {
      _check(epoch, identity);
      throw UsageReportFailure(0, e.code);
    } finally {
      for (final close in closers.reversed) {
        _closers.remove(close);
        close();
      }
    }
  }

  UsageReportFailure _failure(int? status, String code) => UsageReportFailure(
      status ?? 0,
      switch (status) {
        401 => 'DEVICE_UNAUTHENTICATED',
        403 => 'SCOPE_DENIED',
        404 => 'REPORT_NOT_AVAILABLE',
        _ => code
      });
  @override
  void cancel() {
    _epoch++;
    final closers = _closers.toList();
    _closers.clear();
    for (final close in closers.reversed) {
      close();
    }
  }

  @override
  void close() {
    _closed = true;
    cancel();
  }
}
