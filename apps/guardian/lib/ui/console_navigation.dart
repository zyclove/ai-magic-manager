import 'package:flutter/material.dart';
import '../core/console_modules.dart';
import 'design.dart';

final destinations = List<(String, String, IconData)>.unmodifiable([
  for (final module in consoleModules)
    (module.id, module.label, _destinationIcons[module.id]!),
]);

final navigationGroups = List<(String, String, List<String>)>.unmodifiable([
  for (final group in ConsoleModuleGroup.values)
    (
      group.id,
      group.label,
      List<String>.unmodifiable(consoleModules
          .where((module) => module.group == group)
          .map((module) => module.id)),
    ),
]);

const _destinationIcons = <String, IconData>{
  'overview': Icons.space_dashboard_outlined,
  'subjects': Icons.person_outline,
  'classes': Icons.school_outlined,
  'device-groups': Icons.grid_view_outlined,
  'managed-android': Icons.phonelink_lock_outlined,
  'devices': Icons.devices_outlined,
  'applications': Icons.apps_outlined,
  'schedules': Icons.schedule_outlined,
  'quota': Icons.timelapse_outlined,
  'policies': Icons.shield_outlined,
  'approvals': Icons.task_alt_outlined,
  'notifications': Icons.notifications_none_outlined,
  'help-requests': Icons.volunteer_activism_outlined,
  'reports': Icons.bar_chart_outlined,
  'commercial': Icons.workspace_premium_outlined,
  'catalog': Icons.inventory_2_outlined,
  'contracts': Icons.description_outlined,
  'family-finance': Icons.payments_outlined,
  'identity-providers': Icons.verified_user_outlined,
  'managed-android-review': Icons.fact_check_outlined,
  'institution-contracts': Icons.fact_check_outlined,
  'members': Icons.group_outlined,
  'ownership': Icons.swap_horiz_outlined,
  'audit': Icons.receipt_long_outlined,
  'exports': Icons.file_download_outlined,
  'support': Icons.support_agent_outlined,
  'settings': Icons.settings_outlined,
};

String navigationLabel(String section, {bool organization = false}) =>
    consoleModule(section)?.labelFor(organization: organization) ?? '工作台';

/// Shared by the desktop sidebar and mobile drawer; access precedes search.
class ConsoleNavigation extends StatefulWidget {
  final String section;
  final bool Function(String) canOpen;
  final ValueChanged<String> onSelect;
  final bool organization;
  const ConsoleNavigation(
      {super.key,
      required this.section,
      required this.canOpen,
      required this.onSelect,
      this.organization = false});
  @override
  State<ConsoleNavigation> createState() => _ConsoleNavigationState();
}

class _ConsoleNavigationState extends State<ConsoleNavigation> {
  final search = TextEditingController();
  final searchFocus = FocusNode(debugLabel: 'console-function-search');
  final expanded = <String, bool>{
    for (final group in ConsoleModuleGroup.values)
      group.id: group.initiallyExpanded,
  };
  String query = '';
  Set<String> _allowedIds = {};
  String? _lastSubmittedQuery;

  @override
  void initState() {
    super.initState();
    _allowedIds = _availableDestinations().map((d) => d.$1).toSet();
    _revealCurrent();
  }

  @override
  void didUpdateWidget(ConsoleNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextAllowed = _availableDestinations().map((d) => d.$1).toSet();
    final accessChanged = nextAllowed.length != _allowedIds.length ||
        !nextAllowed.containsAll(_allowedIds);
    _allowedIds = nextAllowed;
    if (oldWidget.section != widget.section ||
        oldWidget.organization != widget.organization ||
        accessChanged) {
      search.clear();
      query = '';
      _lastSubmittedQuery = null;
      _revealCurrent();
    }
  }

  void _revealCurrent() {
    for (final group in navigationGroups) {
      if (group.$3.contains(widget.section)) expanded[group.$1] = true;
    }
  }

  @override
  void dispose() {
    searchFocus.dispose();
    search.dispose();
    super.dispose();
  }

  String title((String, String, IconData) destination) =>
      navigationLabel(destination.$1, organization: widget.organization);

  List<(String, String, IconData)> _availableDestinations() =>
      destinations.where((d) => widget.canOpen(d.$1)).toList();

  String _normalizeQuery(String value) =>
      value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  bool _matches((String, String, IconData) destination, String value) {
    if (value.isEmpty) return true;
    final text = [
      title(destination),
      destination.$2,
      ...?consoleModule(destination.$1)?.searchTerms
    ].join(' ').toLowerCase();
    return value.split(' ').every((word) => text.contains(word));
  }

  void _clearSearch() {
    if (!mounted) return;
    search.clear();
    setState(() {
      query = '';
      _lastSubmittedQuery = null;
      _revealCurrent();
    });
    searchFocus.requestFocus();
  }

  void _selectDestination(String id) {
    // A visible tile may outlive its permission until the next rebuild.
    if (mounted && widget.canOpen(id)) widget.onSelect(id);
  }

  void _submitSearch(String submitted) {
    if (!mounted) return;
    final value = _normalizeQuery(search.text);
    final composing = search.value.composing;
    if (value.isEmpty ||
        _normalizeQuery(submitted) != value ||
        value == _lastSubmittedQuery ||
        (composing.isValid && !composing.isCollapsed)) {
      return;
    }
    final matches = _availableDestinations()
        .where((d) => _matches(d, value))
        .toList();
    if (matches.length != 1) return;
    // Repeated IME/Enter submissions for the same query open only once.
    _lastSubmittedQuery = value;
    _selectDestination(matches.single.$1);
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _availableDestinations()
        .where((d) => _matches(d, query))
        .toList();
    return Column(children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: TextField(
              controller: search,
              focusNode: searchFocus,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() {
                    query = _normalizeQuery(value);
                    _lastSubmittedQuery = null;
                  }),
              onEditingComplete: () => searchFocus.requestFocus(),
              onSubmitted: _submitSearch,
              decoration: InputDecoration(
                  labelText: '查找功能',
                  hintText: '输入名称或常用关键词',
                  helperText: query.isEmpty
                      ? null
                      : filtered.length == 1
                          ? '找到 1 项，按 Enter 打开'
                          : filtered.isEmpty
                              ? '换个关键词，或清除搜索'
                              : '找到 ${filtered.length} 项，请选择一项',
                  helperMaxLines: 2,
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 19),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除功能搜索',
                          onPressed: _clearSearch,
                          icon: const Icon(Icons.close, size: 17))))),
      Expanded(
          child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
            if (filtered.isEmpty)
              const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                  child: Text('没有匹配的可用功能，试试其他关键词。',
                      style: TextStyle(color: muted, fontSize: 13))),
            for (final group in navigationGroups)
              if (filtered.any((d) => group.$3.contains(d.$1))) ...[
                Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                    child: Semantics(
                        button: true,
                        expanded:
                            query.isNotEmpty || expanded[group.$1] == true,
                        child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: query.isNotEmpty
                                ? null
                                : () => setState(() => expanded[group.$1] =
                                    !(expanded[group.$1] ?? false)),
                            child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 12),
                                child: Row(children: [
                                  Expanded(
                                      child: Text(group.$2,
                                          style: const TextStyle(
                                              color: muted,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600))),
                                  Icon(
                                      query.isNotEmpty ||
                                              expanded[group.$1] == true
                                          ? Icons.expand_less
                                          : Icons.expand_more,
                                      size: 18,
                                      color: muted)
                                ]))))),
                if (query.isNotEmpty || expanded[group.$1] == true)
                  for (final id in group.$3)
                    for (final d in filtered.where((d) => d.$1 == id))
                      Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: ListTile(
                              minLeadingWidth: 22,
                              contentPadding:
                                  const EdgeInsets.symmetric(horizontal: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                              selected: widget.section == id,
                              selectedTileColor: const Color(0xFFEAF2FC),
                              selectedColor: navy,
                              leading: Icon(d.$3, size: 21),
                              title: Text(title(d),
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: widget.section == id
                                          ? FontWeight.w600
                                          : FontWeight.w400)),
                              onTap: () => _selectDestination(id))),
              ],
          ])),
    ]);
  }
}
