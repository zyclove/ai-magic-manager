import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/cleanup_https_certificate.dart';

// Public self-signed test certificate; no private material. Loading trust
// anchors does not depend on this certificate's handshake validity period.
const _certificate =
    'MIIBczCCARmgAwIBAgIJALuncaUu1HKmMAoGCCqGSM49BAMCMBQxEjAQBgNVBAMTCTEyNy4w'
    'LjAuMTAeFw0yNjEwMTMwNTM3NDFaFw0yNjEwMTUwNTM3NDFaMBQxEjAQBgNVBAMTCTEyNy4w'
    'LjAuMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABPUHcHl+wqe2pPvqX4lxhYYkIkBGDb1E'
    'bbSCQD6QISlr6ZAluKvImOQL3N6UwouBFvn0iZym+t+YST93Ht1riNyjVDBSMB0GA1UdDgQW'
    'BBTpkcl1uNzyW7PZ9hSVRnbalEfvrzALBgNVHQ8EBAMCB4AwDwYDVR0RBAgwBocEfwAAATAT'
    'BgNVHSUEDDAKBggrBgEFBQcDATAKBggqhkjOPQQDAgNIADBFAiB5TxSIHTV3korTUddYOWHF'
    'lvsHU5dYgn6QwGxEg0e+ZAIhAMT0f16J87ZFrNVF2YhQPuA11uYHBgtrm7orzPAWjAbz';

void main() {
  test('Public DER fixture is accepted by Dart TLS after PEM conversion', () {
    final context = SecurityContext(withTrustedRoots: false);
    expect(
        () => context.setTrustedCertificatesBytes(
            cleanupTestCertificatePem(_certificate)),
        returnsNormally);
  });
}
