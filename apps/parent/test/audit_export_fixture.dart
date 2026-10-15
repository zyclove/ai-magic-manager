import 'dart:convert';
import 'package:parent/core/audit.dart';
import 'package:parent/core/parent_api.dart';

const exportTenant = '11111111-1111-1111-1111-111111111111';
const exportId = '22222222-2222-2222-2222-222222222222';
const exportResource = '33333333-3333-3333-3333-333333333333';
final exportNow = DateTime.now().millisecondsSinceEpoch;
AuditQuery get exportFilter => AuditQuery(
    from: exportNow - 60000, to: exportNow, resourceId: exportResource);
Json exportBody() => {
      'schemaVersion': 1,
      'type': 'AUDIT_JSON',
      'tenantId': exportTenant,
      'jobId': exportId,
      'requestedTo': exportNow,
      'generatedAt': exportNow + 1,
      'recordCount': 1,
      'selection': {
        'from': exportNow - 60000,
        'to': exportNow,
        'action': null,
        'resourceId': exportResource,
        'correlationId': null
      },
      'events': [
        {
          'id': exportId,
          'actorId': 'guardian-01',
          'action': 'SUBJECT_CREATED',
          'resourceId': exportResource,
          'correlationId': exportResource,
          'occurredAt': exportNow - 1000
        }
      ]
    };
Json exportJob({String state = 'READY', int? bytes}) => {
      'id': exportId,
      'state': state,
      'createdAt': exportNow,
      'updatedAt': exportNow,
      'expiresAt': exportNow + 86400000,
      'from': exportNow - 60000,
      'to': exportNow,
      'requestedTo': exportNow,
      'action': null,
      'resourceId': exportResource,
      'correlationId': null,
      'recordCount': state == 'READY' ? 1 : null,
      'byteCount': state == 'READY'
          ? (bytes ?? utf8.encode(jsonEncode(exportBody())).length)
          : null,
      'failureCode': null,
      'attempts': state == 'QUEUED' ? 0 : 1
    };
