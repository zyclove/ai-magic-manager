import 'package:flutter/material.dart';
import '../core/api.dart';
import '../core/commercial_entitlements.dart';
import '../core/commercial_repository.dart';
import '../core/session.dart';
import '../ui/commercial_account_view.dart';
import '../ui/design.dart';

const commercialAccountRoles = {'OWNER', 'GUARDIAN', 'ORG_ADMIN', 'AUDITOR'};

/// Fetches the selected tenant's rights and drops results after a workspace or role change.
class CommercialAccountPage extends StatefulWidget {
  final Session session;
  const CommercialAccountPage({super.key, required this.session});

  @override
  State<CommercialAccountPage> createState() => _CommercialAccountPageState();
}

class _CommercialAccountPageState extends State<CommercialAccountPage> {
  late final String root, role, actor;
  late final CommercialRepository repository;
  CommercialEntitlements? rights;
  Object? error;
  bool loading = false;
  int generation = 0;

  bool current() =>
      widget.session.authenticated &&
      widget.session.tenant != null &&
      widget.session.root == root &&
      widget.session.role == role &&
      widget.session.profile?['subject'] == actor &&
      commercialAccountRoles.contains(role);

  @override
  void initState() {
    super.initState();
    root = widget.session.root;
    role = widget.session.role;
    actor = widget.session.profile!['subject'] as String;
    repository = CommercialRepository(
        api: widget.session.api, root: root, current: current);
    widget.session.addListener(accessChanged);
    load();
  }

  void accessChanged() {
    if (!current() && mounted) {
      generation++;
      setState(() {
        rights = null;
        error = const ApiFailure(409, 'WORKSPACE_CHANGED');
        loading = false;
      });
    }
  }

  Future<void> load() async {
    if (!current()) return;
    final ticket = ++generation;
    setState(() {
      loading = true;
      error = null;
      rights = null;
    });
    try {
      final result = await repository.load();
      if (mounted && current() && ticket == generation) {
        setState(() {
          rights = result;
          loading = false;
        });
      }
    } catch (failure) {
      if (mounted && current() && ticket == generation) {
        setState(() {
          error = failure;
          loading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    generation++;
    widget.session.removeListener(accessChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeading('商业账户', '查看经过核验的权益；设备能力与购买资格分开核验。',
            action: OutlinedButton.icon(
                onPressed: loading || !current() ? null : load,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('刷新'))),
        if (loading) const LinearProgressIndicator(),
        if (error != null) FailureView(error!, retry: current() ? load : null),
        if (rights != null) CommercialAccountView(rights: rights!),
        if (!loading && rights == null && error == null)
          const Panel(child: EmptyView('尚无商业账户数据', '请刷新后重试。'))
      ]);
}
