import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../core/family_collaboration.dart';
import '../core/family_notifications.dart';
import '../core/parent_session.dart';
import 'family_invitation_page.dart';
import 'family_inbox_page.dart';

/// One installation coordinator survives navigation and workspace changes.
/// External links are RAM-only until an authenticated adult chooses to join.
class FamilyAppHost extends StatefulWidget {
  final ParentSession session;
  final FamilyNotificationCoordinator? coordinator;
  final Widget Function(
      GlobalKey<NavigatorState>, FamilyNotificationCoordinator) builder;
  const FamilyAppHost(
      {super.key,
      required this.session,
      required this.builder,
      this.coordinator});
  @override
  State<FamilyAppHost> createState() => _FamilyAppHostState();
}

class _FamilyAppHostState extends State<FamilyAppHost>
    with WidgetsBindingObserver {
  final navigator = GlobalKey<NavigatorState>();
  late final FamilyNotificationCoordinator notifications;
  Future<void> Function()? previousGuard;
  final links = const MethodChannel('com.aimanager.parent/links');
  String? stamp;
  bool foreground = true,
      scheduled = false,
      refreshing = false,
      refreshAgain = false,
      opening = false;
  int epoch = 0;
  FamilyInvitationIntent? invitation;
  @override
  void initState() {
    super.initState();
    foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    notifications = widget.coordinator ??
        FamilyNotificationCoordinator(session: widget.session);
    previousGuard = widget.session.beforeIdentityChange;
    widget.session.beforeIdentityChange = _prepare;
    widget.session.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _changed();
  }

  Future<void> _prepare() async {
    epoch++;
    invitation = null;
    await previousGuard?.call();
    // Cloud DELETE may remain pending. Local shutdown must succeed before the
    // session discards the credentials needed for recovery.
    await notifications.beforeScopeChange();
  }

  void _changed() {
    final s = widget.session;
    final next =
        '${s.ready}:${s.authenticated}:${s.profile?['subject']}:${s.tenant?['id']}:${s.role}:${s.generation}';
    if (stamp != next) {
      stamp = next;
      epoch++;
      _schedule();
    }
  }

  void _schedule() {
    if (!mounted || !foreground || scheduled) return;
    scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduled = false;
      if (mounted && foreground) unawaited(_refresh());
    });
  }

  bool _current(int e, String? actor) =>
      mounted &&
      foreground &&
      e == epoch &&
      widget.session.ready &&
      widget.session.authenticated &&
      widget.session.profile?['subject'] == actor;
  void _open(Widget page) {
    final state = navigator.currentState;
    if (state == null) return;
    opening = true;
    unawaited(state
        .push<void>(MaterialPageRoute(builder: (_) => page))
        .then<void>((_) {
      opening = false;
      if (mounted) _schedule();
    }, onError: (Object _) {
      opening = false;
    }));
  }

  Future<void> _refresh() async {
    if (refreshing) {
      refreshAgain = true;
      return;
    }
    refreshing = true;
    final e = epoch,
        s = widget.session,
        actor = widget.session.profile?['subject'] as String?;
    try {
      if (!s.ready) return;
      try {
        await notifications.onResume();
      } catch (_) {/* Settings provide a retry and truthful status. */}
      if (!mounted || !foreground || e != epoch) return;
      try {
        final raw = await links
            .invokeMapMethod<String, dynamic>('takeFamilyInvitation');
        if (raw != null &&
            raw.length == 2 &&
            raw['id'] is String &&
            raw['token'] is String) {
          final candidate = FamilyInvitationIntent(raw['id'], raw['token']);
          if (mounted && foreground && e == epoch) invitation = candidate;
        }
      } catch (_) {/* Unsupported builds have the explicit paste-link entry. */}
      if (!_current(e, actor) || opening) return;
      final pending = invitation;
      if (pending != null) {
        invitation = null;
        _open(
            FamilyInvitationAcceptancePage(session: s, initialIntent: pending));
        return;
      }
      final click = await notifications.takeClick();
      if (click == null ||
          !_current(e, actor) ||
          s.tenant?['kind'] != 'FAMILY' ||
          !s.canDecide) return;
      // An event reference is a hint, never a tenant/actor selector. The inbox
      // reads current authorized facts from the API after opening.
      _open(FamilyInboxPage(session: s));
    } finally {
      refreshing = false;
      if (refreshAgain) {
        refreshAgain = false;
        _schedule();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    epoch++;
    if (foreground) _schedule();
  }

  @override
  void dispose() {
    epoch++;
    invitation = null;
    widget.session.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    if (widget.session.beforeIdentityChange == _prepare) {
      widget.session.beforeIdentityChange = previousGuard;
    }
    if (widget.coordinator == null) notifications.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(navigator, notifications);
}
