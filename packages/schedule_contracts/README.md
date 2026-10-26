# Schedule contracts 1.0.0

Pure Dart schedule contracts for deployment examples and local weekly drafting.
The package has no runtime dependencies and supports Dart 3.4 through Dart 3.x.

`SchedulePreset.readCatalog(Object?)` reads the complete response atomically:

```dart
final examples = SchedulePreset.readCatalog(decodedResponse);
final wallTime = examples.first.weekly.first['start'];
```

The response must contain exactly `schemaVersion` (integer `1`) and `items`.
At most 20 examples are allowed. Each example contains exactly `id`, `name`,
`description`, and 1–56 `weekly` windows. Each window contains exactly `day`,
`start`, and `end`; days are uppercase English weekday identifiers, and times
are exact `HH:mm`. End before start means overnight; equal endpoints are invalid.
Duplicate example IDs and identical day/start/end windows are rejected.

IDs follow `[a-z][a-z0-9-]{0,39}`. Names and descriptions are nonempty, trimmed,
at most 100 and 300 UTF-16 code units respectively, and reject all Unicode control
(`Cc`) and format (`Cf`) characters, matching the backend categories. This uses the SDK's [Unicode-mode RegExp](https://api.dart.dev/dart-core/RegExp/isUnicode.html),
not a hand-maintained subset of invisible characters.
Lists and every window map are independently copied and immutable. Invalid input
throws `FormatException` with a constant message and no raw input attached.

Examples do not contain time zones or date exceptions. Clients retain the user's
IANA zone and exceptions, copy selected weekly values into a local draft, and
save only after explicit confirmation. This package performs no I/O, time-zone or
DST evaluation, recommendation, persistence, or device operation. The HTTP layer
owns authentication, tenant/role authorization and response-size limits.

`maximumWeeklyWindows` defines the 56-row storage limit. The pure
`weeklyWindowAdditions(existing: ..., selectedDays: ..., start: ..., end: ...)`
helper returns only genuinely new weekday/start/end rows, ordered Monday through
Sunday. Repeated selections and rows already present are ignored; existing rows,
including duplicates, remain unchanged. New lists and maps are immutable. Invalid
weekdays, wall times, equal endpoints or existing row shapes throw a constant
`FormatException` without the supplied input. Empty selections are invalid.

The helper performs no mutation or partial insertion and does not enforce the
resulting plan size. Hosts compare `existing.length + additions.length` with
`maximumWeeklyWindows` and reject the entire oversized batch before inserting.
A plan with 55 rows can therefore add one new row selected alongside four rows
already present, rather than rejecting all five selected weekdays. Date-exception
windows keep their separate eight-row limit and do not use this helper.

Guardian contract tests live in
`apps/guardian/test/schedule_presets_contract_test.dart` and
`apps/guardian/test/weekly_window_additions_test.dart`. Parent retains its
existing `SchedulePreset` adapter and maps parser errors to its existing API
exception. Backend origin:
`backend/src/main/java/com/aimanager/schedule/internal/SchedulePresetCatalog.java`.
