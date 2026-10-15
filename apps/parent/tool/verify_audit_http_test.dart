import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:parent/core/audit.dart';
import 'package:parent/core/parent_api.dart';

void main() {
  test(
      'mobile audit reader paginates filters and respects real server authorization',
      () async {
    final encoded = Platform.environment['PARENT_AUDIT_HTTP_FIXTURE'];
    if (encoded == null || encoded.length > 16000) {
      throw StateError('Explicit fixture required');
    }
    final fixture = jsonDecode(encoded) as Json;
    final root = Uri.parse(fixture['apiRoot']);
    if (fixture['testOnly'] != true ||
        root.scheme != 'http' ||
        root.host != '127.0.0.1' ||
        !root.hasPort ||
        root.path != '/api/v1' ||
        root.userInfo.isNotEmpty ||
        root.hasQuery ||
        root.hasFragment) {
      throw StateError('Only loopback fixtures permitted');
    }
    final api =
        ParentApi(() async => fixture['token'], baseUrl: root.toString());
    addTearDown(api.close);
    final repository = ParentAuditRepository(
        api: api, tenant: fixture['tenant'], current: () => true);
    final from = fixture['from'] as int;
    final q =
        AuditQuery(from: from, to: from + 1000, action: 'SUBJECT_CREATED');
    final first = await repository.load(q);
    expect(first.items.length, 20);
    expect(first.nextCursor, isNotNull);
    final last = await repository.load(q, cursor: first.nextCursor);
    expect(last.items.length, 1);
    expect(last.nextCursor, isNull);
    expect(
        first.items.last.occurredAt, greaterThan(last.items.first.occurredAt));
    final item = await repository.detail(first.items.first.id);
    expect(item.actorId, fixture['actor']);
    final filtered = await repository.load(AuditQuery(
        from: from,
        to: from + 1000,
        resourceId: fixture['resource'],
        correlationId: fixture['trace']));
    expect(filtered.items.length, 20);
    final exclusive = await repository
        .load(AuditQuery(from: from, to: from + 20, action: 'SUBJECT_CREATED'));
    expect(exclusive.items.length, 20);
    expect(exclusive.nextCursor, isNull);
    await expectLater(
        repository.load(
            AuditQuery(from: from, to: from + 1000, action: 'SUBJECT_UPDATED'),
            cursor: first.nextCursor),
        throwsA(
            isA<ParentApiException>().having((e) => e.status, 'status', 400)));
    final other = ParentAuditRepository(
        api: api, tenant: fixture['otherTenant'], current: () => true);
    await expectLater(
        other.load(q),
        throwsA(
            isA<ParentApiException>().having((e) => e.status, 'status', 403)));
    final child =
        ParentApi(() async => fixture['childToken'], baseUrl: root.toString());
    addTearDown(child.close);
    await expectLater(
        ParentAuditRepository(
            api: child,
            tenant: fixture['tenant'],
            current: () => true).detail(item.id),
        throwsA(
            isA<ParentApiException>().having((e) => e.status, 'status', 403)));
  });
}
