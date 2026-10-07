import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../anpr_exception.dart';
import '../anpr_result.dart';
import '../anpr_scanner.dart';
import '../anpr_sdk_base.dart';
import '../model_manager.dart';
import 'plate_painter.dart';

/// Drop-in camera view that detects and reads number plates.
///
/// ```dart
/// AnprScannerView(onPlate: (r) => print(r.plateNumber));
/// ```
///
/// Requires AnprSdk.instance.initialize() to have been called (it may still
/// be running: the view shows download progress until it is ready).
class AnprScannerView extends StatefulWidget {
  const AnprScannerView({
    super.key,
    this.onPlate,
    this.scanner,
    this.showBoundingBox = true,
    this.boxColor = Colors.green,
    this.fit = BoxFit.cover,
    this.overlayBuilder,
    this.loadingBuilder,
    this.errorBuilder,
  });

  /// Called for every confirmed plate.
  final void Function(AnprResult result)? onPlate;

  /// Supply your own scanner to control it (stop/start) from outside.
  /// If given, the view will NOT dispose it.
  final AnprScanner? scanner;

  final bool showBoundingBox;
  final Color boxColor;
  final BoxFit fit;

  /// Draw anything on top of the preview using the live result.
  final Widget Function(BuildContext context, AnprResult live)? overlayBuilder;

  /// Replace the default loading screen. [progress] is 0..1 while models
  /// download, null otherwise.
  final Widget Function(BuildContext context, double? progress)? loadingBuilder;

  /// Replace the default error screen. Call [retry] to try again
  /// (camera errors only).
  final Widget Function(
    BuildContext context,
    AnprException error,
    VoidCallback retry,
  )?
  errorBuilder;

  @override
  State<AnprScannerView> createState() => _AnprScannerViewState();
}

class _AnprScannerViewState extends State<AnprScannerView> {
  final AnprSdk _sdk = AnprSdk.instance;
  late final AnprScanner _scanner;
  late final bool _ownsScanner;
  StreamSubscription<AnprResult>? _sub;

  @override
  void initState() {
    super.initState();
    _ownsScanner = widget.scanner == null;
    _scanner = widget.scanner ?? AnprScanner();
    _sub = _scanner.plates.listen((r) => widget.onPlate?.call(r));
    _sdk.status.addListener(_onSdkStatus);
    _maybeStart();
  }

  void _maybeStart() {
    if (_sdk.status.value != AnprSdkStatus.ready) return;
    // Deferred so scanner listeners never fire in the middle of a build.
    scheduleMicrotask(() {
      if (mounted) unawaited(_scanner.start());
    });
  }

  void _onSdkStatus() {
    if (!mounted) return;
    _maybeStart();
    setState(() {});
  }

  @override
  void dispose() {
    _sdk.status.removeListener(_onSdkStatus);
    _sub?.cancel();
    final scanner = _scanner;
    final owns = _ownsScanner;
    // Deferred so notifier changes never happen while the tree is unmounting.
    scheduleMicrotask(
      () => unawaited(owns ? scanner.dispose() : scanner.stop()),
    );
    super.dispose();
  }

  void _retry() => unawaited(_scanner.start());

  @override
  Widget build(BuildContext context) {
    switch (_sdk.status.value) {
      case AnprSdkStatus.uninitialized:
        return _error(
          const AnprException(
            AnprErrorCode.notInitialized,
            'Call AnprSdk.instance.initialize() before showing the scanner.',
          ),
        );
      case AnprSdkStatus.initializing:
        return ValueListenableBuilder<DownloadProgress?>(
          valueListenable: _sdk.downloadProgress,
          builder: (context, p, _) => _loading(context, p?.fraction),
        );
      case AnprSdkStatus.error:
        return _error(
          _sdk.lastError ??
              const AnprException(
                AnprErrorCode.modelSetupFailed,
                'Setup could not be completed.',
              ),
        );
      case AnprSdkStatus.ready:
        return ValueListenableBuilder<AnprScannerStatus>(
          valueListenable: _scanner.status,
          builder: (context, s, _) {
            if (s == AnprScannerStatus.error) {
              return _error(
                _scanner.error ??
                    const AnprException(
                      AnprErrorCode.cameraError,
                      'Camera error.',
                    ),
              );
            }
            return ValueListenableBuilder<CameraController?>(
              valueListenable: _scanner.cameraController,
              builder: (context, cam, _) {
                if (cam == null || !cam.value.isInitialized) {
                  return _loading(context, null);
                }
                return _preview(cam);
              },
            );
          },
        );
    }
  }

  Widget _preview(CameraController cam) {
    final previewSize = cam.value.previewSize!;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: FittedBox(
            fit: widget.fit,
            child: SizedBox(
              width: previewSize.height,
              height: previewSize.width,
              child: CameraPreview(
                cam,
                child: widget.showBoundingBox
                    ? ValueListenableBuilder<AnprResult>(
                        valueListenable: _scanner.live,
                        builder: (context, r, child) => CustomPaint(
                          size: Size.infinite,
                          painter: PlatePainter(
                            rect: r.box,
                            imageWidth: r.frameSize.width.round(),
                            imageHeight: r.frameSize.height.round(),
                            confidence: r.detectionConfidence,
                            color: widget.boxColor,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ),
        ),
        if (widget.overlayBuilder != null)
          Positioned.fill(
            child: ValueListenableBuilder<AnprResult>(
              valueListenable: _scanner.live,
              builder: (ctx, r, _) => widget.overlayBuilder!(ctx, r),
            ),
          ),
      ],
    );
  }

  // ------------------------------------------------------------
  // Default screens (override with loadingBuilder / errorBuilder)
  // ------------------------------------------------------------

  Widget _loading(BuildContext context, double? progress) {
    final custom = widget.loadingBuilder;
    if (custom != null) return custom(context, progress);

    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 64,
              height: 64,
              child: CircularProgressIndicator(value: progress, strokeWidth: 5),
            ),
            const SizedBox(height: 20),
            Text(
              progress == null
                  ? 'Getting things ready…'
                  : 'Setting up… ${(progress * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.black54, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _error(AnprException e) {
    final custom = widget.errorBuilder;
    if (custom != null) return custom(context, e, _retry);

    final canRetry =
        e.code == AnprErrorCode.noCamera ||
        e.code == AnprErrorCode.cameraError ||
        e.code == AnprErrorCode.cameraPermissionDenied;

    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                e.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54, fontSize: 16),
              ),
              if (canRetry) ...[
                const SizedBox(height: 24),
                FilledButton(onPressed: _retry, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
