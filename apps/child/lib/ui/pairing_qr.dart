import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

String readPairingConfirmation(String input,
    {required String tenantId, required String deviceId}) {
  try {
    if (input.length > 1024) throw const FormatException();
    final value = jsonDecode(input);
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['type'] != 'ai-manager-pairing-confirmation' ||
        value['tenantId'] != tenantId ||
        value['deviceId'] != deviceId ||
        value['pairingCode'] is! String ||
        !RegExp(r'^[A-Z0-9]{8}$').hasMatch(value['pairingCode'] as String)) {
      throw const FormatException();
    }
    return value['pairingCode'] as String;
  } catch (_) {
    throw const FormatException('Invalid pairing confirmation');
  }
}

class PairingQr extends StatelessWidget {
  final String data, label;
  const PairingQr({super.key, required this.data, required this.label});
  @override
  Widget build(BuildContext context) => Semantics(
        label: label,
        child: ExcludeSemantics(
            child: LayoutBuilder(
                builder: (context, constraints) => Center(
                      child: DecoratedBox(
                          decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border:
                                  Border.all(color: const Color(0xFFE0E7EC))),
                          child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: QrImageView(
                                data: data,
                                size: math
                                    .min(constraints.maxWidth - 16, 260)
                                    .clamp(120, 260)
                                    .toDouble(),
                                backgroundColor: Colors.white,
                                errorCorrectionLevel: QrErrorCorrectLevel.M,
                              ))),
                    ))),
      );
}
