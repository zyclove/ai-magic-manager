import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/console_routes.dart';

void main() {
  test('controlled list routes preserve exact paths and reject ambiguous queries',
      () {
    expect(deviceConnectionCheckPath, '/devices?connection=NEEDS_CHECK');
    expect(accessRequestsPendingPath, '/approvals?state=PENDING');
    expect(accessRequestsAllPath, '/approvals?state=ALL');
    expect(filteredConsolePaths, {
      deviceConnectionCheckPath,
      accessRequestsPendingPath,
      accessRequestsAllPath,
    });
    for (final entry in {
      deviceConnectionCheckPath: ConsoleListView.connectionCheck,
      accessRequestsPendingPath: ConsoleListView.pending,
      accessRequestsAllPath: ConsoleListView.all,
    }.entries) {
      final uri = Uri.parse(entry.key);
      expect(consoleListViewFor(uri.path.substring(1), uri), entry.value);
    }

    for (final role in [
      'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR', 'TEACHER', 'CHILD', 'UNKNOWN',
    ]) {
      expect(ConsoleListView.pending.pendingFor(role), isTrue);
      expect(ConsoleListView.all.pendingFor(role), isFalse);
      final defaultPending = const {'OWNER', 'GUARDIAN', 'ORG_ADMIN'}.contains(role);
      expect(ConsoleListView.automatic.pendingFor(role), defaultPending);
      expect(ConsoleListView.connectionCheck.pendingFor(role), defaultPending);
    }

    for (final location in [
      '/approvals',
      '/approvals?',
      '/approvals?state',
      '/approvals?state=',
      '/approvals?state=pending',
      '/approvals?state=DENIED',
      '/approvals?state=PENDING&state=PENDING',
      '/approvals?state=PENDING&state=ALL',
      '/approvals?state=PENDING&extra=1',
      '/approvals?connection=NEEDS_CHECK',
      '/devices?state=PENDING',
      '/devices?connection=',
      '/devices?connection=RECENT',
      '/devices?connection=NEEDS_CHECK&connection=NEEDS_CHECK',
      '/devices?connection=NEEDS_CHECK&extra=1',
      '/subjects?state=PENDING',
    ]) {
      final uri = Uri.parse(location);
      expect(consoleListViewFor(uri.path.substring(1), uri),
          ConsoleListView.automatic, reason: location);
    }
    expect(consoleListViewFor('approvals', Uri.parse(deviceConnectionCheckPath)),
        ConsoleListView.automatic);
    expect(consoleListViewFor('devices', Uri.parse(accessRequestsPendingPath)),
        ConsoleListView.automatic);
    expect(consoleListViewFor('approvals', Uri.parse('/approvals/?state=PENDING')),
        ConsoleListView.automatic);
    expect(filteredConsolePaths.contains('/approvals?state=%50ENDING'), isFalse);
    expect(filteredConsolePaths.contains('/approvals?state=PENDING#other'), isFalse);
  });
}
