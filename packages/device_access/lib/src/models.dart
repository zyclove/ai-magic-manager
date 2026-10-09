import 'dart:convert';
import 'package:crypto/crypto.dart';

class AccessFailure implements Exception {
  final String code;
  const AccessFailure(this.code);
  @override
  String toString() => 'AccessFailure($code)';
}

/// Authenticated device facts only. Issuer and trust keys remain installation
/// configuration; a response or an unverified access JWS cannot choose them.
class AccessDeviceContext {
  final String tenantId, subjectId, deviceId, registrationId;
  const AccessDeviceContext._(
      this.tenantId, this.subjectId, this.deviceId, this.registrationId);
  factory AccessDeviceContext.fromJson(Map<String, dynamic> value) {
    const fields = {'tenantId', 'subjectId', 'deviceId', 'registrationId'};
    if (value.length != fields.length ||
        !fields.every((f) => accessId(value[f]))) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    return AccessDeviceContext._(value['tenantId'], value['subjectId'],
        value['deviceId'], value['registrationId']);
  }
  void requireIdentity(
      {required String tenantId,
      required String deviceId,
      required String registrationId}) {
    if (this.tenantId != tenantId ||
        this.deviceId != deviceId ||
        this.registrationId != registrationId) {
      throw const AccessFailure('ACCESS_TARGET_CHANGED');
    }
  }

  @override
  String toString() => 'AccessDeviceContext(authenticated-binding)';
}

class DeviceAccessScope {
  final String issuer, tenantId, subjectId, deviceId, registrationId;
  const DeviceAccessScope(
      {required this.issuer,
      required this.tenantId,
      required this.subjectId,
      required this.deviceId,
      required this.registrationId});
  String get storageKey => sha256
      .convert(utf8.encode(
          jsonEncode([issuer, tenantId, subjectId, deviceId, registrationId])))
      .toString();
}

/// The receive path always validates raw JWS, never a caller-constructed model.
class VerifiedAccessWindow {
  final String compact;
  final Map<String, dynamic> fields;
  VerifiedAccessWindow.internal(this.compact, Map<String, dynamic> fields)
      : fields = freezeAccessJson(fields);
  String get documentId => fields['documentId'];
  String get requestId => fields['requestId'];
  String get policyId => fields['policyId'];
  String get baseVersionId => fields['baseVersionId'];
  String get applicationId => fields['applicationId'];
  List<String> get ruleIds => (fields['ruleIds'] as List).cast<String>();
  String get action => fields['action'];
  bool get isRemoval => action == 'REMOVE_ACCESS_WINDOW';
  int get approvalVersion => fields['approvalVersion'];
  int get grantIssuedAt => fields['grantIssuedAt'];
  int get absoluteNotAfter => fields['absoluteNotAfter'];
  int get documentIssuedAt => fields['documentIssuedAt'];
  bool get systemEnforced => false;
  void requireCurrent(int now) {
    if (isRemoval) return;
    if (!accessInteger(now, 0) ||
        now < grantIssuedAt ||
        now < documentIssuedAt) {
      throw const AccessFailure('CLOCK_UNTRUSTED');
    }
    if (now >= absoluteNotAfter) throw const AccessFailure('EXPIRED');
  }
}

/// Metadata must come from the authenticated device transport, never from a
/// decoded unverified payload. The journal also compares it to the verified JWS.
class AccessDocument {
  final String documentId,
      requestId,
      action,
      signedDocument,
      deliveryState,
      retryStatus;
  final int approvalVersion, documentIssuedAt, deliveryAttempt;
  final String? reasonCode;
  final int? retryAfter;
  const AccessDocument._(
      this.documentId,
      this.requestId,
      this.action,
      this.signedDocument,
      this.deliveryState,
      this.retryStatus,
      this.approvalVersion,
      this.documentIssuedAt,
      this.deliveryAttempt,
      this.reasonCode,
      this.retryAfter);
  factory AccessDocument.fromJson(Map<String, dynamic> json) {
    final rejected = json['deliveryState'] == 'REJECTED';
    if (!accessId(json['documentId']) ||
        !accessId(json['requestId']) ||
        !accessInteger(json['approvalVersion'], 1) ||
        !accessInteger(json['documentIssuedAt'], 0) ||
        !accessInteger(json['deliveryAttempt'], 1) ||
        json['deliveryAttempt'] > 10 ||
        !accessActions.contains(json['action']) ||
        !accessStages.contains(json['deliveryState']) ||
        json['signedDocument'] is! String ||
        (json['signedDocument'] as String).isEmpty ||
        (json['signedDocument'] as String).length > 131072 ||
        !accessRetryStates.contains(json['retryStatus']) ||
        (rejected
            ? !accessRejectionReasons.contains(json['reasonCode'])
            : json['reasonCode'] != null) ||
        (json['retryAfter'] != null && !accessInteger(json['retryAfter'], 0))) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    final waiting = {'WAITING', 'AVAILABLE'}.contains(json['retryStatus']);
    if (waiting != (json['retryAfter'] != null) ||
        (!rejected && json['retryStatus'] != 'NOT_NEEDED')) {
      throw const AccessFailure('TRANSPORT_INVALID');
    }
    return AccessDocument._(
        json['documentId'],
        json['requestId'],
        json['action'],
        json['signedDocument'],
        json['deliveryState'],
        json['retryStatus'],
        json['approvalVersion'],
        json['documentIssuedAt'],
        json['deliveryAttempt'],
        json['reasonCode'],
        json['retryAfter']);
  }
  void requireMatch(VerifiedAccessWindow value) {
    if (documentId != value.documentId ||
        requestId != value.requestId ||
        action != value.action ||
        approvalVersion != value.approvalVersion ||
        documentIssuedAt != value.documentIssuedAt) {
      throw const AccessFailure('TRANSPORT_MISMATCH');
    }
  }
}

const accessMaxInteger = 9007199254740991;
const accessActions = {'UPSERT_ACCESS_WINDOW', 'REMOVE_ACCESS_WINDOW'};
const accessStages = {'SIGNED', 'RECEIVED', 'STORED', 'REJECTED'};
const accessRejectionReasons = {
  'SIGNATURE_INVALID',
  'BASELINE_MISSING',
  'EXPIRED',
  'UNSUPPORTED_SCHEMA',
  'STORAGE_FAILED',
  'WRONG_DEVICE',
  'OTHER'
};
const accessRetryStates = {
  'NOT_NEEDED',
  'WAITING',
  'AVAILABLE',
  'NOT_ALLOWED',
  'WINDOW_ENDING',
  'EXHAUSTED'
};
bool accessId(Object? value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(value);
bool accessInteger(Object? value, int minimum) =>
    value is int && value >= minimum && value <= accessMaxInteger;
dynamic freezeAccessJson(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(
        value.map((key, v) => MapEntry(key, freezeAccessJson(v))));
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(value.map(freezeAccessJson));
  }
  return value;
}
