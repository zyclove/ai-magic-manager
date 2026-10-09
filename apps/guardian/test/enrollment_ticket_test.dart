import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/enrollment_ticket.dart';

void main() {
  test('device import contains only the issued ticket and its tenant', () {
    final value = jsonDecode(encodeEnrollmentTicket('tenant-1', {
      'id': 'ticket-1',
      'token': 'one-time-token',
      'expiresAt': 123456,
      'state': 'PENDING_CLAIM',
      'unexpected': 'excluded',
    }));
    expect(value, {
      'tenantId': 'tenant-1',
      'id': 'ticket-1',
      'token': 'one-time-token',
      'expiresAt': 123456,
    });
  });
}
