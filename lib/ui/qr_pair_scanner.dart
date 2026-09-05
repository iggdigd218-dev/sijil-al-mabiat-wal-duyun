// شاشة مسح QR للاقتران بين الأجهزة.
// تستخدم mobile_scanner نفسها المستخدمة في barcode_scanner.dart.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/sync/qr_pairing.dart';

class PairingData {
  final String ws;
  final String ip;
  final int port;
  final String tok;
  const PairingData({
    required this.ws,
    required this.ip,
    required this.port,
    required this.tok,
  });
}

Future<PairingData?> scanQrPair(BuildContext context) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('مسح QR متاح على الهاتف فقط. يمكنك إدخال البيانات يدوياً')),
    );
    return null;
  }
  return Navigator.of(context).push<PairingData>(
    MaterialPageRoute(builder: (_) => const _QrPairScanner()),
  );
}

class _QrPairScanner extends StatefulWidget {
  const _QrPairScanner();

  @override
  State<_QrPairScanner> createState() => _QrPairScannerState();
}

class _QrPairScannerState extends State<_QrPairScanner> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: [BarcodeFormat.qrCode],
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture cap) {
    if (_handled) return;
    for (final b in cap.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      final parsed = QrPairingService.parseQr(raw);
      if (parsed == null) continue;
      final ws = parsed['ws'] ?? '';
      final ip = parsed['ip'] ?? '';
      final port = int.tryParse(parsed['port'] ?? '') ?? 43053;
      final tok = parsed['tok'] ?? '';
      if (tok.isEmpty || ip.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(PairingData(ws: ws, ip: ip, port: port, tok: tok));
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مسح QR للاقتران'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // Overlay مربع مسح.
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: 0.9), width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                'وجّه الكاميرا إلى QR الظاهر على الجهاز الرئيسي',
                style: TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
