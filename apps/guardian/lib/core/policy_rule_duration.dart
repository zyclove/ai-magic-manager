import 'api.dart';

const _invalidDuration = ApiFailure(400, 'INVALID_DURATION');
const _maximumSeconds = 86400;

int _requireSeconds(Object? value) {
  if (value is! int || value < 1 || value > _maximumSeconds) {
    throw _invalidDuration;
  }
  return value;
}

/// Split the original whole seconds without rounding or changing its duration.
Json policyRuleDurationInitial(Object? originalSeconds) {
  final total = _requireSeconds(originalSeconds);
  return Map<String, dynamic>.unmodifiable({
    'minutes': total ~/ 60,
    'seconds': total % 60,
  });
}

int policyRuleDurationSeconds(Json values) {
  final minutes = values['minutes'];
  final seconds = values['seconds'] ?? 0;
  if (minutes is! int || minutes < 0 || minutes > 1440 ||
      seconds is! int || seconds < 0 || seconds > 59) {
    throw _invalidDuration;
  }
  return _requireSeconds(minutes * 60 + seconds);
}

String policyRuleDurationLabel(Object? seconds) {
  final total = _requireSeconds(seconds);
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final remainder = total % 60;
  return [
    if (hours != 0) '$hours 小时',
    if (minutes != 0) '$minutes 分钟',
    if (remainder != 0) '$remainder 秒',
  ].join(' ');
}
