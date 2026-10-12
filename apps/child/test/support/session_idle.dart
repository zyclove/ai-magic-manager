import 'package:child/core/session.dart';
import 'package:flutter_test/flutter_test.dart';

/// initialize() restores local state, then starts foreground work. Wait for
/// that work before issuing a separate user action in non-widget tests.
Future<void> waitForSessionIdle(ChildSession session) async {
  for (var i = 0; i < 500 && session.busy; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(session.busy, isFalse, reason: 'Session foreground work must settle.');
}
