/// Format accepted whole seconds without changing domain validation or values.
String wholeSecondsLabel(int total) {
  if (total < 0) throw ArgumentError.value(total, 'total', 'Must be nonnegative.');
  if (total == 0) return '0 秒';
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final seconds = total % 60;
  return [
    if (hours != 0) '$hours 小时',
    if (minutes != 0) '$minutes 分钟',
    if (seconds != 0) '$seconds 秒',
  ].join(' ');
}
