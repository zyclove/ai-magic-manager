import 'package:schedule_contracts/schedule_contracts.dart' as contracts;

import 'parent_api.dart';

/// Deployment examples are immutable drafting aids, never saved schedules.
class SchedulePreset {
  final String id, name, description;
  final List<Json> weekly;
  SchedulePreset._(this.id, this.name, this.description, List<Json> rows)
      : weekly = List.unmodifiable(
            rows.map((row) => Map<String, dynamic>.unmodifiable(row)));

  static List<SchedulePreset> readCatalog(dynamic raw) {
    try {
      return List<SchedulePreset>.unmodifiable(
          contracts.SchedulePreset.readCatalog(raw).map((preset) =>
              SchedulePreset._(preset.id, preset.name, preset.description,
                  preset.weekly.map((row) => Json.from(row)).toList())));
    } on FormatException {
      throw const ParentApiException(502, 'INVALID_RESPONSE');
    }
  }
}
