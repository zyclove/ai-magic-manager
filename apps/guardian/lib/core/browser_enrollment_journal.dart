// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import 'enrollment_journal.dart';

/// Same-tab storage adapter. No ticket, claim token or pairing code is stored.
class BrowserEnrollmentJournal extends StoredEnrollmentJournal {
  BrowserEnrollmentJournal() : super(const _BrowserEnrollmentStrings());
}

class _BrowserEnrollmentStrings implements EnrollmentStringStorage {
  const _BrowserEnrollmentStrings();

  @override
  String? read(String key) => html.window.sessionStorage[key];

  @override
  void write(String key, String value) =>
      html.window.sessionStorage[key] = value;

  @override
  void remove(String key) => html.window.sessionStorage.remove(key);
}
