import 'package:device_cleanup/device_cleanup.dart';
import 'package:device_identity/device_identity.dart';
import 'secret_store.dart';

/// Web and unsupported platforms never execute an Android cleanup command.
class AndroidAgentCleanupExecutor implements AgentCleanupExecutor {
  AndroidAgentCleanupExecutor(
      {required DeviceIdentityManager identity,
      required AndroidIdentityStore secureStore,
      required bool Function() ownersClosed});

  @override
  Future<void> clearOwnData(VerifiedCleanupCommand command) =>
      Future.error(AgentCleanupFailure('UNSUPPORTED_AGENT'));

  @override
  Future<void> removeOriginalKey(VerifiedCleanupCommand command) =>
      Future.error(AgentCleanupFailure('UNSUPPORTED_AGENT'));
}
