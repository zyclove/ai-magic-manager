import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';
import 'package:device_policy/device_policy.dart';

/// Encrypted platform storage for the authenticated context and check intent.
abstract interface class ChildAccessBindingStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class ChildAccessEntry {
  final AccessJournalEntry record;
  final String applicationName;
  final bool requiresReview;
  const ChildAccessEntry(this.record, this.applicationName,
      {this.requiresReview = false});
}

class ChildAccessSnapshot {
  final List<ChildAccessEntry> entries;
  final List<AccessSyncIssue> issues;
  final bool contextReady, onlineConfirmed, hasMore;
  final int pendingReceipts;
  final int? lastOnlineAt;
  const ChildAccessSnapshot(
      {this.entries = const [],
      this.issues = const [],
      this.contextReady = false,
      this.onlineConfirmed = false,
      this.hasMore = false,
      this.pendingReceipts = 0,
      this.lastOnlineAt});
  bool get systemEnforced => false;
}

abstract interface class ChildAccessReceiver {
  Future<ChildAccessSnapshot> restore();
  Future<ChildAccessSnapshot> synchronize();
  void pause();
  void resume();
  Future<void> close();
}

typedef ChildAccessBaseline = Future<List<VerifiedConfiguration>> Function();
typedef ChildAccessFactory = Future<ChildAccessReceiver> Function(
    DeviceIdentityView identity, ChildAccessBaseline readBaseline);
