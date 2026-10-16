/// A workspace write has completed; only its subsequent reads need recovery.
class WorkspaceReadRecovery implements Exception {
  final String completedMessage;
  final Object error;
  final Future<void> Function() reload;
  final bool Function() isCurrent;

  const WorkspaceReadRecovery({
    required this.completedMessage,
    required this.error,
    required this.reload,
    required this.isCurrent,
  });

  WorkspaceReadRecovery withError(Object next) => WorkspaceReadRecovery(
      completedMessage: completedMessage,
      error: next,
      reload: reload,
      isCurrent: isCurrent);
}
