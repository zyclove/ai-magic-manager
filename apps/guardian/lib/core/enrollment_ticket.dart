import 'dart:convert';

/// Deliberately excludes service endpoints and adult session credentials.
String encodeEnrollmentTicket(String tenantId, Map<String, dynamic> ticket) =>
    jsonEncode({
      'tenantId': tenantId,
      'id': ticket['id'],
      'token': ticket['token'],
      'expiresAt': ticket['expiresAt'],
    });
