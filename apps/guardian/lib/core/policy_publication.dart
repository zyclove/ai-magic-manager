import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'api.dart';

const publicationMaximumSafeInteger = 9007199254740991;
const publicationMaximumTimestamp = 8640000000000000;
const publicationMaximumPending = 20;
const publicationMaximumRecordBytes = 8192;

final _controls = RegExp(r'[\u0000-\u001f\u007f-\u009f]');
final _uuid =
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
final _requestUuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
final _hash = RegExp(r'^[0-9a-f]{64}$');

bool _text(Object? value, int limit) =>
    value is String &&
    value.trim().isNotEmpty &&
    value.length <= limit &&
    !_controls.hasMatch(value);

bool isPublicationOpaqueId(Object? value) =>
    _text(value, 200) && value != '.' && value != '..';

bool isPublicationRequestId(Object? value) =>
    value is String && value.length == 36 && _requestUuid.hasMatch(value);

bool _previewId(Object? value) =>
    value is String && value.length == 36 && _uuid.hasMatch(value);

bool _integer(Object? value, int minimum, int maximum) =>
    value is int && value >= minimum && value <= maximum;

bool _endpoint(String value) {
  if (!_text(value, 2048)) return false;
  try {
    final uri = Uri.parse(value);
    return const {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
  } on FormatException {
    return false;
  }
}

Never _invalidIntent() =>
    throw const ApiFailure(400, 'INVALID_POLICY_PUBLICATION_INTENT');
Never _invalidReceipt() =>
    throw const ApiFailure(502, 'INVALID_POLICY_PUBLICATION_RESPONSE');
Never _invalidRecord() =>
    throw const ApiFailure(409, 'INVALID_POLICY_PUBLICATION_RECORD');

bool _fields(Object? value, Set<String> fields) =>
    value is Json &&
    value.length == fields.length &&
    fields.every(value.containsKey);

/// Exact creator and backend namespace. Role and a temporary route epoch do not
/// enter the durable slot: changing role cannot bypass an unresolved publication.
final class PublicationOwner {
  final String actorId, tenantId, apiBaseUrl, issuer;

  PublicationOwner(
      {required this.actorId,
      required this.tenantId,
      required this.apiBaseUrl,
      required this.issuer}) {
    if (!_text(actorId, 255) ||
        !isPublicationOpaqueId(tenantId) ||
        !_endpoint(apiBaseUrl) ||
        !_endpoint(issuer)) _invalidIntent();
  }

  String get key => base64Url
      .encode(utf8.encode(jsonEncode([actorId, tenantId, apiBaseUrl, issuer])))
      .replaceAll('=', '');

  Map<String, Object> toJson() => Map.unmodifiable({
        'actorId': actorId,
        'tenantId': tenantId,
        'apiBaseUrl': apiBaseUrl,
        'issuer': issuer,
      });

  factory PublicationOwner.parse(Object? raw) {
    if (!_fields(raw, {'actorId', 'tenantId', 'apiBaseUrl', 'issuer'})) {
      _invalidIntent();
    }
    final value = raw as Json;
    if (value.values.any((entry) => entry is! String)) _invalidIntent();
    return PublicationOwner(
        actorId: value['actorId'],
        tenantId: value['tenantId'],
        apiBaseUrl: value['apiBaseUrl'],
        issuer: value['issuer']);
  }

  @override
  bool operator ==(Object other) =>
      other is PublicationOwner &&
      actorId == other.actorId &&
      tenantId == other.tenantId &&
      apiBaseUrl == other.apiBaseUrl &&
      issuer == other.issuer;
  @override
  int get hashCode => Object.hash(actorId, tenantId, apiBaseUrl, issuer);
}

/// One original request. Restoring this value never authorizes replay. The
/// preview expiry applies only to a newly authorized POST, never to result GET.
final class PublicationIntent {
  final PublicationOwner owner;
  final String policyId, previewId, previewHash, idempotencyKey, mode;
  final int revision, previewExpiresAt, createdAt;

  PublicationIntent(
      {required this.owner,
      required this.policyId,
      required this.revision,
      required this.previewId,
      required this.previewHash,
      required this.previewExpiresAt,
      required this.createdAt,
      required this.idempotencyKey,
      this.mode = 'CONFIGURE_ONLY'}) {
    if (!isPublicationOpaqueId(policyId) ||
        !_previewId(previewId) ||
        previewHash.length != 64 ||
        !_hash.hasMatch(previewHash) ||
        !isPublicationRequestId(idempotencyKey) ||
        mode != 'CONFIGURE_ONLY' ||
        !_integer(revision, 0, publicationMaximumSafeInteger) ||
        !_integer(createdAt, 0, publicationMaximumTimestamp) ||
        !_integer(previewExpiresAt, 1, publicationMaximumTimestamp)) {
      _invalidIntent();
    }
  }

  Json get body => Map<String, dynamic>.unmodifiable({
        'previewId': previewId,
        'previewHash': previewHash,
        'mode': mode,
      });

  Map<String, Object> toJson() => Map.unmodifiable({
        'owner': owner.toJson(),
        'policyId': policyId,
        'revision': revision,
        'previewId': previewId,
        'previewHash': previewHash,
        'previewExpiresAt': previewExpiresAt,
        'createdAt': createdAt,
        'idempotencyKey': idempotencyKey,
        'mode': mode,
      });

  factory PublicationIntent.parse(Object? raw) {
    if (!_fields(raw, {
      'owner',
      'policyId',
      'revision',
      'previewId',
      'previewHash',
      'previewExpiresAt',
      'createdAt',
      'idempotencyKey',
      'mode'
    })) _invalidIntent();
    final value = raw as Json;
    if (!['policyId', 'previewId', 'previewHash', 'idempotencyKey', 'mode']
            .every((key) => value[key] is String) ||
        !['revision', 'previewExpiresAt', 'createdAt']
            .every((key) => value[key] is int)) _invalidIntent();
    return PublicationIntent(
        owner: PublicationOwner.parse(value['owner']),
        policyId: value['policyId'],
        revision: value['revision'],
        previewId: value['previewId'],
        previewHash: value['previewHash'],
        previewExpiresAt: value['previewExpiresAt'],
        createdAt: value['createdAt'],
        idempotencyKey: value['idempotencyKey'],
        mode: value['mode']);
  }

  @override
  bool operator ==(Object other) =>
      other is PublicationIntent &&
      owner == other.owner &&
      policyId == other.policyId &&
      revision == other.revision &&
      previewId == other.previewId &&
      previewHash == other.previewHash &&
      previewExpiresAt == other.previewExpiresAt &&
      createdAt == other.createdAt &&
      idempotencyKey == other.idempotencyKey &&
      mode == other.mode;
  @override
  int get hashCode => Object.hash(owner, policyId, revision, previewId,
      previewHash, previewExpiresAt, createdAt, idempotencyKey, mode);
}

/// Parse the actual six-field CONFIGURE_ONLY response before showing success.
/// These fields do not echo the original input; request correlation remains
/// owned by the scoped repository and server's committed-result lookup.
final class PublicationReceipt {
  final String id, versionId, mode, state;
  final int sequence, createdAt;
  const PublicationReceipt._(this.id, this.versionId, this.sequence, this.mode,
      this.state, this.createdAt);

  factory PublicationReceipt.parse(Object? raw) {
    if (!_fields(
        raw, {'id', 'versionId', 'sequence', 'mode', 'state', 'createdAt'})) {
      _invalidReceipt();
    }
    final value = raw as Json;
    if (!isPublicationOpaqueId(value['id']) ||
        !isPublicationOpaqueId(value['versionId']) ||
        !_integer(value['sequence'], 1, publicationMaximumSafeInteger) ||
        value['mode'] != 'CONFIGURE_ONLY' ||
        value['state'] != 'CONFIGURED_NOT_ENFORCED' ||
        !_integer(value['createdAt'], 1, publicationMaximumTimestamp)) {
      _invalidReceipt();
    }
    return PublicationReceipt._(value['id'], value['versionId'],
        value['sequence'], value['mode'], value['state'], value['createdAt']);
  }

  @override
  bool operator ==(Object other) =>
      other is PublicationReceipt &&
      id == other.id &&
      versionId == other.versionId &&
      sequence == other.sequence &&
      mode == other.mode &&
      state == other.state &&
      createdAt == other.createdAt;
  @override
  int get hashCode =>
      Object.hash(id, versionId, sequence, mode, state, createdAt);
}

enum PublicationPhase {
  unknown('UNKNOWN'),
  reauthenticationRequired('REAUTH_REQUIRED'),
  resultExpired('RESULT_EXPIRED'),
  resultErased('RESULT_ERASED');

  final String value;
  const PublicationPhase(this.value);

  bool get terminal =>
      this == resultExpired || this == resultErased;
}

enum PublicationTerminalReason {
  expired,
  erased;

  PublicationPhase get phase => this == expired
      ? PublicationPhase.resultExpired
      : PublicationPhase.resultErased;
}

/// Opaque fingerprint of an original request, never a new replay credential.
String publicationRequestDigest(PublicationIntent intent) => sha256
    .convert(utf8.encode(jsonEncode([
      intent.owner.key, intent.policyId, intent.idempotencyKey,
    ])))
    .toString();

/// The durable phase and monotonic attempt fence are part of every CAS. A late
/// 401 or successful-response cleanup must never change a later attempt.
final class PublicationPending {
  final PublicationIntent intent;
  final PublicationPhase phase;
  final int attempt;
  final bool confirmedSuccess;
  PublicationPending(
      {required this.intent,
      this.phase = PublicationPhase.unknown,
    this.attempt = 1,
    this.confirmedSuccess = false}) {
    if (!_integer(attempt, 1, publicationMaximumSafeInteger) ||
        (confirmedSuccess && !phase.terminal)) _invalidRecord();
  }

  Map<String, Object> toJson() => Map.unmodifiable({
        'schema': 1,
        'intent': intent.toJson(),
        'phase': phase.value,
        'attempt': attempt,
        if (phase.terminal) 'confirmedSuccess': confirmedSuccess,
      });

  String encode() {
    final value = jsonEncode(toJson());
    if (utf8.encode(value).length > publicationMaximumRecordBytes) {
      _invalidRecord();
    }
    return value;
  }

  static PublicationPending decode(
    String text, {
    required PublicationOwner owner,
    required String policyId,
  }) {
    if (text.isEmpty ||
        utf8.encode(text).length > publicationMaximumRecordBytes) {
      _invalidRecord();
    }
    try {
      final raw = jsonDecode(text);
      final terminal = raw is Json &&
          const {'RESULT_EXPIRED', 'RESULT_ERASED'}.contains(raw['phase']);
      if (!_fields(raw, {
        'schema', 'intent', 'phase', 'attempt',
        if (terminal) 'confirmedSuccess',
      })) {
        _invalidRecord();
      }
      final value = raw as Json;
      if (value['schema'] is! int ||
          value['schema'] != 1 ||
          value['attempt'] is! int ||
          (terminal && value['confirmedSuccess'] is! bool)) {
        _invalidRecord();
      }
      final intent = PublicationIntent.parse(value['intent']);
      if (intent.owner != owner || intent.policyId != policyId) {
        _invalidRecord();
      }
      final phase = PublicationPhase.values.firstWhere(
          (entry) => entry.value == value['phase'],
          orElse: _invalidRecord);
      return PublicationPending(
          intent: intent, phase: phase, attempt: value['attempt'],
          confirmedSuccess: terminal && value['confirmedSuccess'] == true);
    } catch (_) {
      // Stored text is untrusted. Never attach payloads or parsing causes.
      _invalidRecord();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PublicationPending &&
      intent == other.intent &&
      phase == other.phase &&
      attempt == other.attempt && confirmedSuccess == other.confirmedSuccess;
  @override
  int get hashCode => Object.hash(intent, phase, attempt, confirmedSuccess);
}

/// Redacted durable fence. Contains no original key, preview, payload or receipt.
final class PublicationTerminalMarker {
  final String ownerKey, policyId, requestDigest;
  final PublicationTerminalReason reason;
  final int acknowledgedAt;
  final bool confirmedSuccess;

  PublicationTerminalMarker({required this.ownerKey, required this.policyId,
    required this.requestDigest, required this.reason,
    required this.acknowledgedAt, required this.confirmedSuccess}) {
    if (ownerKey.isEmpty || ownerKey.length > 12000 ||
        !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(ownerKey) ||
        !isPublicationOpaqueId(policyId) || requestDigest.length != 64 ||
        !_hash.hasMatch(requestDigest) ||
        !_integer(acknowledgedAt, 1, publicationMaximumTimestamp)) {
      _invalidRecord();
    }
  }

  String encode() {
    final value = jsonEncode({
      'schema': 1, 'ownerKey': ownerKey, 'policyId': policyId,
      'requestDigest': requestDigest, 'reason': reason.name,
      'acknowledgedAt': acknowledgedAt, 'confirmedSuccess': confirmedSuccess,
    });
    if (utf8.encode(value).length > publicationMaximumRecordBytes) _invalidRecord();
    return value;
  }

  static PublicationTerminalMarker decode(String text,
      {required PublicationIntent intent}) {
    if (text.isEmpty || utf8.encode(text).length > publicationMaximumRecordBytes) {
      _invalidRecord();
    }
    try {
      final raw = jsonDecode(text);
      if (!_fields(raw, {'schema', 'ownerKey', 'policyId', 'requestDigest',
          'reason', 'acknowledgedAt', 'confirmedSuccess'})) _invalidRecord();
      final value = raw as Json;
      if (value['schema'] != 1 || value['schema'] is! int ||
          value['ownerKey'] != intent.owner.key ||
          value['policyId'] != intent.policyId ||
          value['requestDigest'] != publicationRequestDigest(intent) ||
          value['acknowledgedAt'] is! int || value['confirmedSuccess'] is! bool) {
        _invalidRecord();
      }
      return PublicationTerminalMarker(ownerKey: value['ownerKey'],
          policyId: value['policyId'], requestDigest: value['requestDigest'],
          reason: PublicationTerminalReason.values.firstWhere(
              (entry) => entry.name == value['reason'], orElse: _invalidRecord),
          acknowledgedAt: value['acknowledgedAt'],
          confirmedSuccess: value['confirmedSuccess']);
    } catch (_) {
      _invalidRecord();
    }
  }

  @override
  bool operator ==(Object other) => other is PublicationTerminalMarker &&
      ownerKey == other.ownerKey && policyId == other.policyId &&
      requestDigest == other.requestDigest && reason == other.reason &&
      acknowledgedAt == other.acknowledgedAt &&
      confirmedSuccess == other.confirmedSuccess;
  @override
  int get hashCode => Object.hash(ownerKey, policyId, requestDigest, reason,
      acknowledgedAt, confirmedSuccess);
}

final class PublicationReservation {
  final PublicationPending record;
  final bool maySubmit;
  const PublicationReservation({required this.record, required this.maySubmit});
}
