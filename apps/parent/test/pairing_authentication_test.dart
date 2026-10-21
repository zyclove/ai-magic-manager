import 'package:flutter_test/flutter_test.dart';
import 'package:parent/core/parent_api.dart';
import 'package:parent/core/parent_session.dart';

class _Session extends ParentSession {
  int authentications = 0;
  bool accepted = true;
  void Function()? afterAuthentication;
  @override
  Future<bool> reauthenticate() async {
    authentications++;
    afterAuthentication?.call();
    return accepted;
  }
}

void main() {
  test('valid server authentication completes pairing without another login',
      () async {
    final session = _Session();
    addTearDown(session.dispose);
    expect(
        await session.pairingRequest(() async => 'connected',
            isCurrent: () => true),
        'connected');
    expect(session.authentications, 0);
  });
  test('only a definite server reauthentication rejection prompts once',
      () async {
    final session = _Session();
    addTearDown(session.dispose);
    var calls = 0;
    final value = await session.pairingRequest(() async {
      if (++calls == 1) throw const ParentApiException(401, 'REAUTH_REQUIRED');
      return 'connected';
    }, isCurrent: () => true);
    expect(value, 'connected');
    expect(calls, 2);
    expect(session.authentications, 1);
  });
  test('unknown network outcomes are never replayed or used to request login',
      () async {
    final session = _Session();
    addTearDown(session.dispose);
    var calls = 0;
    await expectLater(
        session.pairingRequest(() async {
          calls++;
          throw const ParentApiException(0, 'NETWORK_ERROR');
        }, isCurrent: () => true),
        throwsA(isA<ParentApiException>()
            .having((e) => e.code, 'code', 'NETWORK_ERROR')));
    expect(calls, 1);
    expect(session.authentications, 0);
  });
  test('changed workspace after authentication prevents the pairing mutation',
      () async {
    final session = _Session();
    addTearDown(session.dispose);
    var current = true, calls = 0;
    session.afterAuthentication = () => current = false;
    await expectLater(
        session.pairingRequest(() async {
          calls++;
          throw const ParentApiException(401, 'REAUTH_REQUIRED');
        }, isCurrent: () => current),
        throwsA(isA<ParentApiException>()
            .having((e) => e.code, 'code', 'SCOPE_DENIED')));
    expect(calls, 1);
  });
  test('cancelled authentication and repeated rejection do not loop', () async {
    final session = _Session()..accepted = false;
    addTearDown(session.dispose);
    var calls = 0;
    Future<void> request() async {
      calls++;
      throw const ParentApiException(401, 'REAUTH_REQUIRED');
    }

    await expectLater(session.pairingRequest(request, isCurrent: () => true),
        throwsA(isA<ParentApiException>()));
    expect(calls, 1);
    session.accepted = true;
    await expectLater(session.pairingRequest(request, isCurrent: () => true),
        throwsA(isA<ParentApiException>()));
    expect(calls, 3);
    expect(session.authentications, 2);
  });
}
