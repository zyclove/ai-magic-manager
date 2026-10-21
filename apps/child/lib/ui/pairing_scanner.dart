import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// QR data is validated by the caller before returning. No URL is followed.
class PairingScannerPage extends StatefulWidget {
  final String title, instruction;
  final bool Function(String) accepts;
  const PairingScannerPage(
      {super.key,
      required this.title,
      required this.instruction,
      required this.accepts});
  @override
  State<PairingScannerPage> createState() => _PairingScannerPageState();
}

class _PairingScannerPageState extends State<PairingScannerPage> {
  final controller =
      MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool returning = false;
  String? error;
  void detect(BarcodeCapture capture) {
    if (returning || !mounted) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value == null) continue;
      if (!widget.accepts(value)) {
        if (error == null) setState(() => error = '二维码不匹配，请扫描当前配对页面的二维码。');
        continue;
      }
      returning = true;
      unawaited(_finish(value));
      return;
    }
  }

  Future<void> _finish(String value) async {
    try {
      await controller.stop();
    } catch (_) {/* Dispose still closes the camera. */}
    if (mounted) Navigator.of(context).pop(value);
  }

  @override
  void dispose() {
    unawaited(controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: SafeArea(
            child: Column(children: [
          Padding(
              padding: const EdgeInsets.all(20),
              child: Text(widget.instruction,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center)),
          Expanded(
              child: ClipRect(
                  child: MobileScanner(
            controller: controller,
            onDetect: detect,
            errorBuilder: (context, failure, child) => Center(
                child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.no_photography_outlined, size: 48),
                      const SizedBox(height: 16),
                      Text(
                          failure.errorCode ==
                                  MobileScannerErrorCode.permissionDenied
                              ? '未获得相机权限。可返回使用手动连接，或在系统设置中允许相机后重试。'
                              : '暂时无法使用相机。请返回使用手动连接。',
                          textAlign: TextAlign.center),
                    ]))),
            overlayBuilder: (context, constraints) => const IgnorePointer(
                child: Center(
                    child: SizedBox(
                        width: 250,
                        height: 250,
                        child: DecoratedBox(
                            decoration: BoxDecoration(
                                border: Border.fromBorderSide(
                                    BorderSide(color: Colors.white, width: 3)),
                                borderRadius:
                                    BorderRadius.all(Radius.circular(20))))))),
          ))),
          if (error != null)
            Padding(
                padding: const EdgeInsets.all(16),
                child: Text(error!, textAlign: TextAlign.center)),
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回，使用手动连接')),
          const SizedBox(height: 12),
        ])),
      );
}
