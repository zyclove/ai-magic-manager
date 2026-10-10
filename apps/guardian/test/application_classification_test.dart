import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/api.dart';
import 'package:guardian/core/application_classification.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const classificationIdentity = ApplicationClassificationIdentity(
    'ANDROID', 'PRIMARY', 'org.example.reader');
Json classificationFixture(
        {String category = 'UNCLASSIFIED', int version = 0}) =>
    {
      'identity': {
        'platform': 'ANDROID',
        'profile': 'PRIMARY',
        'packageName': 'org.example.reader'
      },
      'category': category,
      'source': version == 0 ? 'NONE' : 'ADMIN_DECLARED',
      'version': version,
      'updatedAt': version == 0 ? null : 1791590400000,
    };
void main() {
  test('classification parser preserves explicit source and exact identity',
      () {
    final value = ApplicationClassification.parse(
        classificationFixture(), classificationIdentity);
    expect(value.category, 'UNCLASSIFIED');
    expect(value.source, 'NONE');
    for (final invalid in [
      {...(classificationFixture()..remove('updatedAt')), 'unexpected': true},
      {...classificationFixture(), 'category': 'GUESSED'},
      {...classificationFixture(), 'source': 'VERIFIED'},
      {...classificationFixture(), 'version': 0.0},
      {...classificationFixture(), 'updatedAt': 1},
      {...classificationFixture(), 'category': 'GAMES'},
      {
        ...classificationFixture(),
        'identity': {
          'platform': 'ANDROID',
          'profile': 'PRIMARY',
          'packageName': 'org.example.Reader'
        }
      },
    ]) {
      expect(
          () =>
              ApplicationClassification.parse(invalid, classificationIdentity),
          throwsA(isA<UsageReportFailure>()));
    }
  });
  test('versioned writes preserve key and reject inconsistent server results',
      () async {
    http.Request? sent;
    var response = classificationFixture(category: 'EDUCATION', version: 1);
    final repository = ApplicationClassificationRepository(
        api: Api(() async => MockClient((r) async {
              sent = r;
              return http.Response(jsonEncode(response), 200);
            })),
        root: '/tenants/11111111-1111-1111-1111-111111111111',
        applicationId: '22222222-2222-2222-2222-222222222222',
        identity: classificationIdentity,
        current: () => true);
    final before = ApplicationClassification.parse(
        classificationFixture(), classificationIdentity);
    await repository.save(before, 'EDUCATION', 'same-request');
    expect(sent!.headers['If-Match'], '"0"');
    expect(sent!.headers['Idempotency-Key'], 'same-request');
    expect(jsonDecode(sent!.body), {'category': 'EDUCATION'});
    response = classificationFixture(category: 'TOOLS', version: 1);
    await expectLater(repository.save(before, 'EDUCATION', 'same-request'),
        throwsA(isA<ApiFailure>()));
  });
  test('late workspace response is discarded', () async {
    var current = true;
    final repository = ApplicationClassificationRepository(
        api: Api(() async => MockClient((_) async {
              current = false;
              return http.Response(jsonEncode(classificationFixture()), 200);
            })),
        root: '/tenants/11111111-1111-1111-1111-111111111111',
        applicationId: '22222222-2222-2222-2222-222222222222',
        identity: classificationIdentity,
        current: () => current);
    await expectLater(
        repository.load(),
        throwsA(isA<ApiFailure>()
            .having((e) => e.code, 'code', 'WORKSPACE_CHANGED')));
  });
}
