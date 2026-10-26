import 'dart:convert';

import '../core/api.dart';
import '../core/labels.dart';
import '../core/rule_parameter_labels.dart';

/// A read-only rendering of the captured submission, not a saved-state claim.
String scheduleDraftText(Json draft) {
  final lines = <String>['计划名称：${_field(draft, 'name')}'];
  final definition = draft['definition'];
  if (definition is! Map) {
    lines.add('定义：${_field(draft, 'definition')}');
  } else {
    lines.add('时区：${_field(definition, 'timeZone')}');
    final weekly = definition['weekly'];
    if (weekly is! List) {
      lines.add('每周时段：${_field(definition, 'weekly')}');
    } else if (weekly.isEmpty) {
      lines.add('每周时段：未设置每周时段，仅按日期例外安排。');
    } else {
      lines.add('每周时段：');
      for (var index = 0; index < weekly.length; index++) {
        final window = weekly[index];
        lines.add(window is Map
            ? '  ${index + 1}. ${_caption(window, 'day')} ${_windowText(window)}'
            : '  ${index + 1}. ${_value(window)}');
        if (window is Map) {
          _otherSettings(lines, window, const {'day', 'start', 'end'});
        }
      }
    }
    final exceptions = definition['exceptions'];
    if (exceptions is! List) {
      lines.add('日期例外：${_field(definition, 'exceptions')}');
    } else if (exceptions.isEmpty) {
      lines.add('日期例外：无。');
    } else {
      lines.add('日期例外：');
      for (final exception in exceptions) {
        if (exception is! Map) {
          lines.add('  ${_value(exception)}');
          continue;
        }
        final date = _field(exception, 'date');
        final windows = exception['windows'];
        if (windows is! List) {
          lines.add('  $date：${_field(exception, 'windows')}');
        } else if (windows.isEmpty) {
          lines.add('  $date：全天关闭');
        } else {
          lines.add('  $date：');
          for (final window in windows) {
            lines.add(window is Map
                ? '    ${_windowText(window)}'
                : '    ${_value(window)}');
            if (window is Map) {
              _otherSettings(lines, window, const {'start', 'end'});
            }
          }
        }
        _otherSettings(lines, exception, const {'date', 'windows'});
      }
    }
    _otherSettings(
        lines, definition, const {'timeZone', 'weekly', 'exceptions'});
  }
  _otherSettings(lines, draft, const {'name', 'definition'});
  return lines.join('\n');
}

/// Directory entries supply names only; every reference keeps its complete ID.
String policyDraftText(Json draft,
    {required String kind,
    List<Json> applications = const [],
    List<Json> schedules = const []}) {
  final lines = <String>[
    '策略名称：${_field(draft, 'name')}',
    '策略类型：${_caption(draft.containsKey('kind') ? draft : {'kind': kind}, 'kind')}',
  ];
  final rules = draft['rules'];
  if (rules is! List) {
    lines.add('规则：${_field(draft, 'rules')}');
  } else if (rules.isEmpty) {
    lines.add('规则：无。');
  } else {
    for (var index = 0; index < rules.length; index++) {
      final rule = rules[index];
      lines.add('规则 ${index + 1}：');
      if (rule is! Map) {
        lines.add('  ${_value(rule)}');
        continue;
      }
      final required = rule['required'];
      final support = required is bool
          ? (required ? '必须支持' : '可选执行')
          : _field(rule, 'required');
      lines.addAll([
        '  规则编号：${_field(rule, 'id')}',
        '  类型：${_caption(rule, 'kind')}',
        '  效果：${_caption(rule, 'effect')}',
        '  支持要求：$support',
      ]);
      if (rule.containsKey('priority')) {
        lines.add('  优先级：${_field(rule, 'priority')}');
      }
      if (rule.containsKey('applicationId')) {
        lines.add('  应用：${_referenceText(rule['applicationId'], applications, 'displayName')}');
      }
      if (rule.containsKey('scheduleId')) {
        lines.add('  时间计划：${_referenceText(rule['scheduleId'], schedules, 'name')}');
      }
      if (rule.containsKey('seconds')) {
        final seconds = rule['seconds'];
        lines.add('  时长：${_field(rule, 'seconds')}${seconds is num ? ' 秒' : ''}');
      }
      if (rule.containsKey('domain')) {
        lines.add('  域名：${_field(rule, 'domain')}');
      }
      if (rule.containsKey('permission')) {
        final permission = rule['permission'];
        const androidPrefix = 'android.permission.';
        final name = permission is String
            ? (permission.startsWith(androidPrefix)
                ? runtimePermissionNames[permission.substring(androidPrefix.length)]
                : specialAccessNames[permission])
            : null;
        lines.add('  权限：${name == null ? _field(rule, 'permission') : '$name（$permission）'}');
      }
      _otherSettings(lines, rule, const {
        'id', 'kind', 'effect', 'required', 'priority', 'applicationId',
        'scheduleId', 'seconds', 'domain', 'permission',
      });
    }
  }
  _otherSettings(lines, draft, const {'name', 'kind', 'rules'});
  return lines.join('\n');
}

String _field(Map source, String key) =>
    source.containsKey(key) ? _value(source[key]) : '未提供';

String _value(Object? value) {
  if (value == null) return '未提供（null）';
  if (value is String) return value.isEmpty ? '空文本（""）' : value;
  return jsonEncode(value);
}

String _caption(Map source, String key) {
  final value = source[key];
  if (value is! String) return _field(source, key);
  final translated = label(value);
  return translated == value ? _value(value) : translated;
}

String _windowText(Map window) {
  final start = window['start'], end = window['end'];
  final time = RegExp(r'^(?:[01][0-9]|2[0-3]):[0-5][0-9]$');
  final overnight = start is String &&
      end is String &&
      time.hasMatch(start) &&
      time.hasMatch(end) &&
      end.compareTo(start) < 0;
  return '${_field(window, 'start')} – ${_field(window, 'end')}'
      '${overnight ? '（跨午夜，结束于次日）' : ''}';
}

String _referenceText(Object? id, List<Json> entries, String nameKey) {
  if (id is! String || id.isEmpty) return _value(id);
  for (final entry in entries) {
    final name = entry[nameKey];
    if (entry['id'] == id && name is String && name.trim().isNotEmpty) {
      return '$name（编号：$id）';
    }
  }
  return '编号：$id';
}

void _otherSettings(List<String> lines, Map source, Set<String> shown) {
  final other = {
    for (final entry in source.entries)
      if (!shown.contains(entry.key)) entry.key: entry.value,
  };
  if (other.isNotEmpty) lines.add('  其他设置：${jsonEncode(other)}');
}
