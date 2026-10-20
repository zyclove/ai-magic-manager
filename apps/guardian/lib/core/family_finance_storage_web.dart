// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'finance_storage_port.dart';

FinanceStringStorage createFinanceStorage() => const _TabStorage();

class _TabStorage implements FinanceStringStorage {
  const _TabStorage();
  @override
  String? read(String key) => html.window.sessionStorage[key];
  @override
  void write(String key, String value) =>
      html.window.sessionStorage[key] = value;
  @override
  void remove(String key) => html.window.sessionStorage.remove(key);
}
