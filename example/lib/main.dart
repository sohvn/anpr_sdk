import 'dart:async';

import 'package:anpr_sdk/anpr_sdk.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Start loading the local TFLite models before the scanner is shown.
  unawaited(
    AnprSdk.instance.initialize().catchError((Object error) {
      debugPrint('ANPR initialization failed: $error');
    }),
  );

  runApp(const AnprDemoApp());
}

class AnprDemoApp extends StatelessWidget {
  const AnprDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ANPR Camera Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.green,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const AnprDemoPage(),
    );
  }
}

class AnprDemoPage extends StatefulWidget {
  const AnprDemoPage({super.key});

  @override
  State<AnprDemoPage> createState() => _AnprDemoPageState();
}

class _AnprDemoPageState extends State<AnprDemoPage> {
  String? _lastConfirmedPlate;
  double? _lastDetectionConfidence;
  double? _lastOcrConfidence;
  DateTime? _lastReadAt;

  void _onPlateDetected(AnprResult result) {
    if (!mounted || result.plateNumber == null) return;

    setState(() {
      _lastConfirmedPlate = result.plateNumber;
      _lastDetectionConfidence = result.detectionConfidence;
      _lastOcrConfidence = result.ocrConfidence;
      _lastReadAt = result.timestamp;
    });

    debugPrint(
      'Confirmed plate: ${result.plateNumber}, '
      'det=${result.detectionConfidence.toStringAsFixed(2)}, '
      'ocr=${result.ocrConfidence.toStringAsFixed(2)}, '
      'detection=${result.detectionMs.toStringAsFixed(1)}ms, '
      'ocr=${result.ocrMs.toStringAsFixed(1)}ms',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnprScannerView(
            onPlate: _onPlateDetected,
            showBoundingBox: true,
            boxColor: Colors.greenAccent,
            fit: BoxFit.cover,
            overlayBuilder: (context, live) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Top status panel.
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.70),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.document_scanner,
                                color: Colors.greenAccent,
                                size: 28,
                              ),
                              SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'ANPR LIVE SCANNER',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    SizedBox(height: 3),
                                    Text(
                                      'Point the camera at a number plate',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                Icons.circle,
                                color: Colors.greenAccent,
                                size: 10,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Live processing details at the bottom.
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: 0,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.82),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: Colors.greenAccent.withValues(alpha: 0.6),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'LIVE OCR',
                                style: TextStyle(
                                  color: Colors.greenAccent,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                live.plateNumber ?? 'Searching for a plate…',
                                style: TextStyle(
                                  fontSize: live.plateNumber == null ? 17 : 28,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 2,
                                ),
                              ),
                              const SizedBox(height: 14),
                              const Divider(height: 1),
                              const SizedBox(height: 12),
                              _MetricRow(
                                label: 'Detection confidence',
                                value:
                                    '${(live.detectionConfidence * 100).toStringAsFixed(0)}%',
                              ),
                              const SizedBox(height: 6),
                              _MetricRow(
                                label: 'Detection time',
                                value:
                                    '${live.detectionMs.toStringAsFixed(1)} ms',
                              ),
                              const SizedBox(height: 6),
                              _MetricRow(
                                label: 'OCR time',
                                value: '${live.ocrMs.toStringAsFixed(1)} ms',
                              ),
                              const SizedBox(height: 14),
                              const Text(
                                'LAST CONFIRMED PLATE',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 5),
                              Text(
                                _lastConfirmedPlate ?? 'Nothing confirmed yet',
                                style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (_lastConfirmedPlate != null) ...[
                                const SizedBox(height: 5),
                                Text(
                                  'Detection: ${((_lastDetectionConfidence ?? 0) * 100).toStringAsFixed(0)}%  •  '
                                  'OCR: ${((_lastOcrConfidence ?? 0) * 100).toStringAsFixed(0)}%',
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                                if (_lastReadAt != null)
                                  Text(
                                    'Read at ${_lastReadAt!.toLocal().toString().substring(11, 19)}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                  ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 13,
            ),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}
