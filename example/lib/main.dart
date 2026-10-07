import 'dart:async';

import 'package:anpr_sdk/anpr_sdk.dart';
import 'package:flutter/material.dart';

/// Run with:
///   flutter run --dart-define=ANPR_TOKEN=your_token
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Start loading as early as possible. The scanner view shows download
  // progress by itself, so there is no need to await this.
  unawaited(
    AnprSdk.instance
        .initialize(apiToken: const String.fromEnvironment('ANPR_TOKEN'))
        .catchError((Object e) => debugPrint('ANPR init failed: $e')),
  );

  runApp(const MaterialApp(home: ScanPage()));
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  String? _plate;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          AnprScannerView(
            onPlate: (r) => setState(() => _plate = r.plateNumber),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  _plate ?? 'Point the camera at a number plate',
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
