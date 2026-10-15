import 'dart:async';
import 'package:device_identity/device_identity.dart';
import 'package:flutter/services.dart';

/// Fixed AndroidX feedback route. No caller-selected key, severity, URL or message.
class AndroidManagedFeedback implements ManagedAgentFeedbackPort {
  static const _channel = MethodChannel('com.aimanager.child/managed_feedback');
  bool _closed = false;
  int _generation = 0;
  @override
  Future<void> submit(ManagedAgentBindingProof proof) async {
    if (_closed) {
      throw const DeviceIdentityFailure('MANAGED_FEEDBACK_UNAVAILABLE');
    }
    final generation = _generation;
    try {
      final value = await _channel.invokeMapMethod<String, dynamic>('submit', {
        'proof': proof.compact,
      }).timeout(const Duration(seconds: 12));
      if (_closed ||
          generation != _generation ||
          value?.length != 1 ||
          value?['status'] != 'SUBMITTED') {
        throw const FormatException();
      }
    } catch (_) {
      throw const DeviceIdentityFailure('MANAGED_FEEDBACK_UNAVAILABLE');
    }
  }

  @override
  void pause() {
    _generation++;
    unawaited(_channel.invokeMethod<void>('pause').catchError((Object _) {}));
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    pause();
  }
}
