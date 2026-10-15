import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android SAF chooses a document first. No plaintext is sent to the native
/// side until the session, server permission and payload have been rechecked.
class AuditExportDestination {
  final MethodChannel channel;
  const AuditExportDestination(
      {this.channel =
          const MethodChannel('com.aimanager.parent/audit-export')});
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  Future<String?> choose(String jobId) async {
    if (!supported) throw PlatformException(code: 'UNSUPPORTED');
    return channel.invokeMethod<String>('choose', {'jobId': jobId});
  }

  Future<void> write(String ticket, Uint8List bytes) async {
    if (await channel
            .invokeMethod<bool>('write', {'ticket': ticket, 'bytes': bytes}) !=
        true) {
      throw PlatformException(code: 'SAVE_FAILED');
    }
  }

  Future<void> abort() async {
    await channel.invokeMethod<void>('abort');
  }
}
