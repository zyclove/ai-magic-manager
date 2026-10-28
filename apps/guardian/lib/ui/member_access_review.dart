import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/labels.dart';
import '../core/member_access.dart';
import 'design.dart';

/// Read-only comparison of a frozen baseline and the canonical local draft.
/// Directory names supplement display; they never decide the diff or a save.
class MemberAccessReview extends StatelessWidget {
  final Json original, proposed;
  final Map<String, String> subjectNames, classNames;
  const MemberAccessReview({super.key, required this.original,
      required this.proposed, this.subjectNames = const {},
      this.classNames = const {}});

  String _scopeLabel(Json scope) {
    final subject = scope['subjectId'];
    return memberScope({...scope,
      if (subjectNames.containsKey(subject)) 'subjectName': subjectNames[subject],
    });
  }

  @override
  Widget build(BuildContext context) {
    final previousSubject = original['subjectId'] as String?;
    final nextSubject = proposed['subjectId'] as String?;
    final previousClasses = Set<String>.from(original['classIds'] as List? ?? const []);
    final nextClasses = Set<String>.from(proposed['classIds'] as List? ?? const []);
    final added = nextClasses.difference(previousClasses).toList()..sort();
    final removed = previousClasses.difference(nextClasses).toList()..sort();
    final roleChanged = original['role'] != proposed['role'];
    final subjectChanged = previousSubject != nextSubject;
    final changed = roleChanged || subjectChanged || added.isNotEmpty || removed.isNotEmpty;
    final references = <({String label, String id, String? name})>[
      if (subjectChanged && previousSubject != null)
        (label: '原档案', id: previousSubject, name: subjectNames[previousSubject]),
      if (subjectChanged && nextSubject != null)
        (label: '调整后档案', id: nextSubject, name: subjectNames[nextSubject]),
      for (final id in added) (label: '新增班级', id: id, name: classNames[id]),
      for (final id in removed) (label: '移除班级', id: id, name: classNames[id]),
    ];
    return Container(
        key: const Key('member-access-change-review'),
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: canvas,
            border: Border.all(color: line),
            borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('本次调整', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (!changed)
            const Text('尚未修改权限。', style: TextStyle(color: muted))
          else ...[
            Text(roleChanged
                ? '角色：${label(original['role'])} → ${label(proposed['role'])}'
                : '角色：${label(proposed['role'])}'),
            const SizedBox(height: 4),
            Text('调整后范围：${_scopeLabel(proposed)}'),
            if (subjectChanged)
              Text(nextSubject == null ? '原关联档案将移除。' : '关联档案将变更。'),
            if (added.isNotEmpty || removed.isNotEmpty)
              Text('班级范围：新增 ${added.length} 个，移除 ${removed.length} 个'),
            if (references.isNotEmpty)
              ExpansionTile(
                  key: const Key('member-access-change-identifiers'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('查看范围变化'),
                  children: [
                    for (final reference in references)
                      Padding(padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Align(alignment: Alignment.centerLeft,
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${reference.label}${reference.name == null ? '' : ' · ${reference.name}'}',
                                        style: const TextStyle(fontSize: 12, color: muted)),
                                    const SizedBox(height: 4),
                                    SelectableText(reference.id),
                                  ]))),
                  ]),
          ],
        ]));
  }
}
