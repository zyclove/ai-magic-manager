/// Exact internal locations admitted by the login return-path allowlist.
const deviceConnectionCheckPath = '/devices?connection=NEEDS_CHECK';
const accessRequestsPendingPath = '/approvals?state=PENDING';
const accessRequestsAllPath = '/approvals?state=ALL';

const filteredConsolePaths = <String>{
  deviceConnectionCheckPath,
  accessRequestsPendingPath,
  accessRequestsAllPath,
};

/// List presentation only. Neither a route nor its default grants permission.
enum ConsoleListView {
  automatic,
  all,
  pending,
  connectionCheck;

  bool pendingFor(String role) => switch (this) {
        pending => true,
        all => false,
        _ => const {'OWNER', 'GUARDIAN', 'ORG_ADMIN'}.contains(role),
      };
}

/// Recognizes only the supported single-value filter for this exact page.
/// Keep login return-path checks on the exact constants above, not parsed URLs.
ConsoleListView consoleListViewFor(String section, Uri uri) {
  if (uri.path != '/$section') return ConsoleListView.automatic;
  final parameters = uri.queryParametersAll;
  if (parameters.length != 1 || parameters.values.single.length != 1) {
    return ConsoleListView.automatic;
  }
  if (section == 'devices' &&
      parameters['connection']?.single == 'NEEDS_CHECK') {
    return ConsoleListView.connectionCheck;
  }
  if (section == 'approvals') {
    return switch (parameters['state']?.single) {
      'PENDING' => ConsoleListView.pending,
      'ALL' => ConsoleListView.all,
      _ => ConsoleListView.automatic,
    };
  }
  return ConsoleListView.automatic;
}
