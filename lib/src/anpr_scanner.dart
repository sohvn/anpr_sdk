import 'dart:async';
import 'dart:io' show Platform;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'anpr_exception.dart';
import 'anpr_result.dart';
import 'anpr_sdk_base.dart';
import 'frame_processing.dart';
import 'plate_voter.dart';

enum AnprScannerStatus { idle, starting, running, error }

/// Headless live scanner: owns the camera, runs detection + OCR on frames and
/// reports plates. Use [AnprScannerView] if you want the preview too.
///
/// ```dart
/// final scanner = AnprScanner(onPlate: (r) => print(r.plateNumber));
/// await scanner.start();
/// ...
/// await scanner.dispose();
/// ```
///
/// [start] never throws: failures are reported through [status] / [error].
class AnprScanner with WidgetsBindingObserver {
  AnprScanner({
    this.onPlate,
    this.lensDirection = CameraLensDirection.back,
    this.resolution = ResolutionPreset.high,
    AnprSdk? sdk,
  }) : _sdk = sdk ?? AnprSdk.instance {
    WidgetsBinding.instance.addObserver(this);
  }

  final AnprSdk _sdk;
  final CameraLensDirection lensDirection;
  final ResolutionPreset resolution;

  /// Called once per confirmed plate (see AnprSdkConfig.confirmReads).
  final void Function(AnprResult result)? onPlate;

  /// Every confirmed plate, as a broadcast stream.
  Stream<AnprResult> get plates => _plates.stream;
  final StreamController<AnprResult> _plates = StreamController.broadcast();

  /// Updates on every processed frame (box, current text, timings).
  final ValueNotifier<AnprResult> live = ValueNotifier(AnprResult.empty());

  final ValueNotifier<AnprScannerStatus> status = ValueNotifier(
    AnprScannerStatus.idle,
  );

  /// Non-null when [status] is [AnprScannerStatus.error].
  AnprException? error;

  /// The active camera controller (null while stopped), for CameraPreview.
  final ValueNotifier<CameraController?> cameraController = ValueNotifier(null);

  CameraController? _camera;
  late final PlateVoter _voter = PlateVoter(
    window: _sdk.config.voteWindow,
    maxReads: _sdk.config.voteMaxReads,
  );

  bool _wantRunning = false;
  bool _processing = false;
  bool _cameraBusy = false;
  bool _disposed = false; // set first: stop all processing
  bool _closed = false; // set last: notifiers are gone

  DateTime _lastDetection = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastOcr = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPlateSeen = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastConfirmedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastConfirmedText;

  // ============================================================
  // PUBLIC
  // ============================================================

  Future<void> start() async {
    if (_disposed) return;
    _wantRunning = true;
    await _openCamera();
  }

  Future<void> stop() async {
    _wantRunning = false;
    await _closeCamera();
  }

  /// Dispose AFTER any [AnprScannerView] using it has been removed.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _wantRunning = false;
    WidgetsBinding.instance.removeObserver(this);
    await _closeCamera();
    for (int i = 0; i < 40 && (_processing || _cameraBusy); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _closed = true;
    await _plates.close();
    live.dispose();
    status.dispose();
    cameraController.dispose();
  }

  // ============================================================
  // LIFECYCLE
  // ============================================================

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        unawaited(_closeCamera());
        break;
      case AppLifecycleState.resumed:
        if (_wantRunning &&
            _camera == null &&
            status.value != AnprScannerStatus.error) {
          unawaited(_openCamera());
        }
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  // ============================================================
  // CAMERA
  // ============================================================

  void _setStatus(AnprScannerStatus s) {
    if (!_closed) status.value = s;
  }

  void _fail(AnprException e) {
    error = e;
    _camera = null;
    if (!_closed) cameraController.value = null;
    _setStatus(AnprScannerStatus.error);
  }

  Future<void> _openCamera() async {
    if (_cameraBusy || _disposed || _camera != null) return;

    if (!_sdk.isReady) {
      _fail(
        const AnprException(
          AnprErrorCode.notInitialized,
          'Call AnprSdk.instance.initialize() and wait for it to finish '
          'before starting the scanner.',
        ),
      );
      return;
    }

    _cameraBusy = true;
    error = null;
    _setStatus(AnprScannerStatus.starting);

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw const AnprException(AnprErrorCode.noCamera, 'No camera found.');
      }

      final description = cameras.firstWhere(
        (c) => c.lensDirection == lensDirection,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        description,
        resolution,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );

      await controller.initialize();

      try {
        await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      } catch (_) {}

      if (_disposed || !_wantRunning) {
        await controller.dispose();
        _setStatus(AnprScannerStatus.idle);
        return;
      }

      _camera = controller;
      cameraController.value = controller;
      _setStatus(AnprScannerStatus.running);

      await controller.startImageStream(_onCameraFrame);
    } on AnprException catch (e) {
      _fail(e);
    } on CameraException catch (e) {
      final denied = e.code.toLowerCase().contains('access');
      _fail(
        AnprException(
          denied
              ? AnprErrorCode.cameraPermissionDenied
              : AnprErrorCode.cameraError,
          denied
              ? 'Camera permission denied. Enable it in system settings and retry.'
              : 'Camera error: ${e.description ?? e.code}',
          cause: e,
        ),
      );
    } catch (e) {
      _fail(
        AnprException(AnprErrorCode.cameraError, 'Camera error: $e', cause: e),
      );
    } finally {
      _cameraBusy = false;
    }
  }

  Future<void> _closeCamera() async {
    final cam = _camera;
    if (cam == null) return;
    _camera = null;
    if (!_closed) cameraController.value = null;
    try {
      if (cam.value.isStreamingImages) {
        await cam.stopImageStream();
      }
    } catch (_) {}
    try {
      await cam.dispose();
    } catch (_) {}
    if (status.value == AnprScannerStatus.running) {
      _setStatus(AnprScannerStatus.idle);
    }
  }

  // ============================================================
  // FRAME PIPELINE
  // ============================================================

  void _onCameraFrame(CameraImage image) {
    if (_processing || _disposed || !_sdk.isReady) return;

    final now = DateTime.now();
    if (now.difference(_lastDetection) < _sdk.config.detectionInterval) return;

    _lastDetection = now;
    _processing = true;

    unawaited(
      _process(image)
          .catchError((Object e, StackTrace st) {
            debugPrint('ANPR FRAME ERROR: $e\n$st');
          })
          .whenComplete(() => _processing = false),
    );
  }

  void _publish(AnprResult state) {
    if (_disposed) return;
    live.value = state;
  }

  Future<void> _process(CameraImage image) async {
    final engine = _sdk.requireEngine();
    final cfg = _sdk.config;

    final rotation = _camera?.description.sensorOrientation ?? 0;
    final frame = FrameData.fromCameraImage(image, rotation);
    final frameSize = Size(
      frame.rotatedWidth.toDouble(),
      frame.rotatedHeight.toDouble(),
    );

    final yoloTimer = Stopwatch()..start();
    final detection = await engine.detect(frame);
    yoloTimer.stop();
    final yoloMs = yoloTimer.elapsedMicroseconds / 1000.0;

    final now = DateTime.now();

    // ---- No plate ----
    if (detection == null) {
      final sinceSeen = now.difference(_lastPlateSeen);
      var state = live.value.copyWith(
        detectionMs: yoloMs,
        frameSize: frameSize,
        timestamp: now,
      );
      if (sinceSeen > cfg.boxGrace) {
        state = state.copyWith(clearBox: true, detectionConfidence: 0);
      }
      if (sinceSeen > cfg.textClear) {
        _voter.clear();
        _lastConfirmedText = null;
        state = state.copyWith(clearPlate: true, ocrConfidence: 0, ocrMs: 0);
      }
      _publish(state);
      return;
    }

    // ---- Plate found ----
    _lastPlateSeen = now;
    _publish(
      live.value.copyWith(
        box: detection.box,
        detectionConfidence: detection.confidence,
        detectionMs: yoloMs,
        frameSize: frameSize,
        timestamp: now,
      ),
    );

    if (now.difference(_lastOcr) < cfg.ocrInterval) return;
    _lastOcr = now;

    final ocrTimer = Stopwatch()..start();
    final result = await engine.recognize(frame, detection.box);
    ocrTimer.stop();
    if (_disposed) return;
    final ocrMs = ocrTimer.elapsedMicroseconds / 1000.0;

    if (result != null &&
        result.confidence >= cfg.ocrMinConfidence &&
        result.text.length >= cfg.ocrMinLength) {
      final t = DateTime.now();
      _voter.add(result.text, result.confidence, t);
      final best = _voter.best ?? result.text;

      final updated = live.value.copyWith(
        plateNumber: best,
        ocrConfidence: result.confidence,
        ocrMs: ocrMs,
        timestamp: t,
      );
      _publish(updated);
      _maybeConfirm(updated, best, t);
    } else {
      _publish(live.value.copyWith(ocrMs: ocrMs));
    }
  }

  void _maybeConfirm(AnprResult updated, String best, DateTime t) {
    final cfg = _sdk.config;
    if (_voter.countOf(best) < cfg.confirmReads) return;
    if (best == _lastConfirmedText &&
        t.difference(_lastConfirmedAt) < cfg.repeatCooldown) {
      return;
    }

    _lastConfirmedText = best;
    _lastConfirmedAt = t;

    final confirmed = updated.copyWith(isConfirmed: true);
    _publish(confirmed);
    onPlate?.call(confirmed);
    if (!_plates.isClosed) _plates.add(confirmed);
  }
}
