import 'dart:convert';
import 'package:flutter/foundation.dart';

/// Deployment values are immutable for this installation. A ticket cannot
/// replace the origin, issuer or public trust ring. No private key belongs here.
class ChildEnvironment {
  final Uri apiRoot;
  final String configurationIssuer;
  final Map<String, dynamic>? configurationKeys;
  final bool allowLoopbackHttp;
  ChildEnvironment(
      {required this.apiRoot,
      this.configurationIssuer = '',
      this.configurationKeys,
      this.allowLoopbackHttp = false}) {
    if (apiRoot.host.isEmpty ||
        apiRoot.userInfo.isNotEmpty ||
        apiRoot.hasQuery ||
        apiRoot.hasFragment ||
        !apiRoot.path.endsWith('/api/v1') ||
        apiRoot.pathSegments.any((p) => p == '.' || p == '..') ||
        !(apiRoot.scheme == 'https' ||
            (allowLoopbackHttp &&
                apiRoot.scheme == 'http' &&
                const {'localhost', '127.0.0.1', '::1'}
                    .contains(apiRoot.host)))) {
      throw const FormatException('Invalid deployment origin');
    }
  }
  static ChildEnvironment? fromBuild() {
    const root = String.fromEnvironment('CHILD_API_ROOT');
    if (root.isEmpty) return null;
    const ring = String.fromEnvironment('CONFIGURATION_JWKS');
    try {
      if (kReleaseMode && const bool.fromEnvironment('ALLOW_LOCAL_HTTP')) {
        throw const FormatException('Release requires HTTPS');
      }
      return ChildEnvironment(
          apiRoot: Uri.parse(root),
          configurationIssuer:
              const String.fromEnvironment('CONFIGURATION_ISSUER'),
          configurationKeys:
              ring.isEmpty ? null : Map<String, dynamic>.from(jsonDecode(ring)),
          allowLoopbackHttp: const bool.fromEnvironment('ALLOW_LOCAL_HTTP'));
    } catch (_) {
      throw const FormatException('Invalid child deployment configuration');
    }
  }
}
