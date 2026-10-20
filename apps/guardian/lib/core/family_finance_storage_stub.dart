import 'finance_storage_port.dart';

FinanceStringStorage createFinanceStorage() => const _UnavailableStorage();

class _UnavailableStorage implements FinanceStringStorage {
  const _UnavailableStorage();
  @override
  String? read(String key) => throw StateError('Tab storage unavailable');
  @override
  void write(String key, String value) =>
      throw StateError('Tab storage unavailable');
  @override
  void remove(String key) => throw StateError('Tab storage unavailable');
}
