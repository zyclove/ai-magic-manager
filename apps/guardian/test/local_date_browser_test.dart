@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:guardian/core/local_date.dart';

void main() {
  test('quota date follows the specified IANA zone across midnight and DST',
      () {
    final moment = DateTime.utc(2026, 10, 9, 2);
    expect(localDateInZone(moment, 'Asia/Shanghai'), '2026-10-09');
    expect(localDateInZone(moment, 'America/Los_Angeles'), '2026-10-08');
    expect(
        localDateInZone(DateTime.utc(2026, 11, 1, 5, 30), 'America/New_York'),
        '2026-11-01');
    expect(
        localDateInZone(DateTime.utc(2026, 11, 1, 6, 30), 'America/New_York'),
        '2026-11-01');
    expect(localDateInZone(moment, 'Invalid/Zone'), '');
  });
}
