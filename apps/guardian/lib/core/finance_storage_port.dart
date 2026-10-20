abstract interface class FinanceStringStorage {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}
