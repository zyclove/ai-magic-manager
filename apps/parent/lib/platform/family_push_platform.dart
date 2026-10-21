import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool canonicalPushId(Object? value) =>
    value is String &&
    RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
        .hasMatch(value);

class FamilyPushState {
  final bool configured, permissionGranted, channelEnabled;
  const FamilyPushState(
      {required this.configured,
      required this.permissionGranted,
      required this.channelEnabled});
  factory FamilyPushState.fromMap(Map value) {
    if (value['configured'] is! bool ||
        value['permissionGranted'] is! bool ||
        value['channelEnabled'] is! bool) {
      throw const FormatException('Invalid notification state');
    }
    return FamilyPushState(
        configured: value['configured'],
        permissionGranted: value['permissionGranted'],
        channelEnabled: value['channelEnabled']);
  }
}

class FamilyPushClick {
  final String eventId;
  final String? installationId;
  const FamilyPushClick(this.eventId, {this.installationId});
  static FamilyPushClick? parse(String value) {
    if (value.length > 100) return null;
    final match =
        RegExp(r'^aimanager://notifications/([0-9a-f-]+)$').firstMatch(value);
    return match != null && canonicalPushId(match[1])
        ? FamilyPushClick(match[1]!)
        : null;
  }
}

/// The official native SDK owns its token. Dart never invents or persists it.
class FamilyPushPlatform {
  final MethodChannel channel;
  const FamilyPushPlatform(
      {this.channel = const MethodChannel('com.aimanager.parent/family-push')});
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<FamilyPushState> state() async {
    if (!supported) {
      return const FamilyPushState(
          configured: false, permissionGranted: false, channelEnabled: false);
    }
    return FamilyPushState.fromMap(
        await channel.invokeMapMethod<String, dynamic>('state') ?? const {});
  }

  Future<FamilyPushState> requestPermission() async => FamilyPushState.fromMap(
      await channel.invokeMapMethod<String, dynamic>('requestPermission') ??
          const {});
  Future<String> register() async {
    final value = await channel.invokeMethod<String>('register');
    if (value == null ||
        value.length < 8 ||
        value.length > 512 ||
        !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(value)) {
      throw const FormatException('Invalid SDK registration');
    }
    return value;
  }

  Future<void> activate(String installationId) async {
    if (!canonicalPushId(installationId)) {
      throw const FormatException('Invalid installation');
    }
    if (await channel.invokeMethod<bool>(
            'activate', {'installationId': installationId}) !=
        true) throw StateError('Notification activation unavailable');
  }

  Future<void> deactivate({bool preserveClick = false}) async {
    if (!supported) return;
    if (await channel.invokeMethod<bool>(
            'deactivate', {'preserveClick': preserveClick}) !=
        true) throw StateError('Notification shutdown unavailable');
  }

  Future<FamilyPushClick?> takeClick() async {
    if (!supported) return null;
    final raw = await channel.invokeMapMethod<String, dynamic>('takeClick');
    if (raw == null ||
        !canonicalPushId(raw['installationId']) ||
        raw['deepLink'] is! String) return null;
    final parsed = FamilyPushClick.parse(raw['deepLink']);
    return parsed == null
        ? null
        : FamilyPushClick(parsed.eventId,
            installationId: raw['installationId']);
  }
}
