/// Mirrors the server's persisted membership permissions; never grants API access.
bool canOpenSection(String role, String section) {
  if (section == 'overview' || section == 'settings') return true;
  if (role == 'OWNER' || role == 'ORG_ADMIN') return true;
  if (role == 'GUARDIAN') return section != 'members';
  if (role == 'AUDITOR') {
    return ['applications', 'schedules', 'policies', 'audit'].contains(section);
  }
  if (role == 'CHILD') {
    return ['subjects', 'devices', 'approvals'].contains(section);
  }
  return false;
}

/// Only the most recently requested workspace may become active.
class SelectionGeneration {
  int _generation = 0;
  int begin() => ++_generation;
  bool current(int generation) => generation == _generation;
  void invalidate() => _generation++;
}
