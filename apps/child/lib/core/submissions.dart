import 'package:device_access/device_access.dart';
import 'package:device_identity/device_identity.dart';

class ChildSubmissionSnapshot {
  final SubmissionJournalView? journal;
  final List<AccessSubmissionOption> options;
  final Set<String> confirmedRequestIds;
  final bool contextReady, onlineConfirmed;
  final String? optionsCursor, requestsCursor;
  final int? lastCheckedAt;
  const ChildSubmissionSnapshot(
      {this.journal,
      this.options = const [],
      this.confirmedRequestIds = const {},
      this.contextReady = false,
      this.onlineConfirmed = false,
      this.optionsCursor,
      this.requestsCursor,
      this.lastCheckedAt});
}

abstract interface class ChildSubmissions {
  Future<ChildSubmissionSnapshot> restore();
  Future<ChildSubmissionSnapshot> refresh();
  Future<ChildSubmissionSnapshot> moreOptions();
  Future<ChildSubmissionSnapshot> moreRequests();
  Future<ChildSubmissionSnapshot> detail(String id);
  Future<ChildSubmissionSnapshot> create(AccessSubmissionInput input,
      {required String applicationName, required String key});
  Future<ChildSubmissionSnapshot> cancel(AccessSubmission value,
      {required String applicationName, required String key});
  Future<ChildSubmissionSnapshot> retry();
  Future<ChildSubmissionSnapshot> discard();
  void pause();
  void resume();
  Future<void> close();
}

typedef ChildSubmissionFactory = Future<ChildSubmissions> Function(
    DeviceIdentityView identity);
