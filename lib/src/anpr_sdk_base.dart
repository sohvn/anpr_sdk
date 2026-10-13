import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'anpr_config.dart';
import 'anpr_engine.dart';
import 'anpr_exception.dart';
import 'anpr_result.dart';
import 'frame_processing.dart';
import 'model_manager.dart';

enum AnprSdkStatus { uninitialized, initializing, ready, error }

/// Entry point. Call [initialize] once (e.g. in main()), then use
/// [AnprScannerView], [AnprScanner] or [recognizeImage].
class AnprSdk {
  AnprSdk._();

  static final AnprSdk instance = AnprSdk._();

  /// Current state. Listen to it to build your own loading UI.
  final ValueNotifier<AnprSdkStatus> status = ValueNotifier(
    AnprSdkStatus.uninitialized,
  );

  /// First-run download progress; null when not downloading.
  final ValueNotifier<DownloadProgress?> downloadProgress = ValueNotifier(null);

  /// Last initialization error, if [status] is [AnprSdkStatus.error].
  AnprException? lastError;

  AnprSdkConfig _config = const AnprSdkConfig();
  AnprEngine? _engine;
  Future<void>? _initFuture;

  AnprSdkConfig get config => _config;
  bool get isReady => status.value == AnprSdkStatus.ready && _engine != null;

  /// Downloads (first run only) and loads the models.
  ///
  /// Safe to call repeatedly: returns immediately once ready, and concurrent
  /// calls share one run. Throws [AnprException] on failure; call again to
  /// retry. After the first successful run the models are cached and this
  /// works fully offline.
  Future<void> initialize({
    required String apiToken,
    AnprSdkConfig config = const AnprSdkConfig(),
    void Function(String status)? onStatus,
  }) {
    if (isReady) return Future<void>.value();
    return _initFuture ??= _doInitialize(
      apiToken,
      config,
      onStatus,
    ).whenComplete(() => _initFuture = null);
  }

  Future<void> _doInitialize(
    String apiToken,
    AnprSdkConfig config,
    void Function(String status)? onStatus,
  ) async {
    status.value = AnprSdkStatus.initializing;
    lastError = null;

    final manager = ModelManager(
      apiToken: apiToken,
      workerUrl: config.workerUrl,
    );

    Future<ModelFiles> load() => manager.loadModels(
      onStatus: onStatus,
      onProgress: (p) => downloadProgress.value = p,
    );

    try {
      var files = await load();
      AnprEngine engine;
      try {
        engine = await AnprEngine.create(files, config);
      } catch (e) {
        // Cached files may be corrupt: wipe and download once more.
        debugPrint('ANPR: model load failed ($e), re-downloading');
        await manager.clearCache();
        files = await load();
        engine = await AnprEngine.create(files, config);
      }

      await _engine?.close();
      _engine = engine;
      _config = config;
      downloadProgress.value = null;
      status.value = AnprSdkStatus.ready;
    } on AnprException catch (e) {
      downloadProgress.value = null;
      lastError = e;
      status.value = AnprSdkStatus.error;
      rethrow;
    } catch (e, st) {
      debugPrint('ANPR INIT ERROR: $e\n$st');
      downloadProgress.value = null;
      final ex = AnprException(
        AnprErrorCode.modelSetupFailed,
        'Setup could not be completed. Please try again.',
        cause: e,
      );
      lastError = ex;
      status.value = AnprSdkStatus.error;
      throw ex;
    }
  }

  /// Internal: used by [AnprScanner].
  AnprEngine requireEngine() {
    final engine = _engine;
    if (engine == null || !isReady) {
      throw const AnprException(
        AnprErrorCode.notInitialized,
        'Call AnprSdk.instance.initialize() and wait for it to finish first.',
      );
    }
    return engine;
  }

  // ============================================================
  // STILL IMAGES
  // ============================================================

  /// Detects and reads the best plate in an encoded image (JPEG/PNG/...).
  ///
  /// Returns null if no plate was found. If a plate box was found but the text
  /// was unreadable, returns a result with [AnprResult.plateNumber] == null.
  /// The image must be upright (EXIF rotation is not applied here).
  Future<AnprResult?> recognizeImage(Uint8List imageBytes) async {
    final engine = requireEngine();
    final frame = await _decodeToFrame(imageBytes);
    final frameSize = ui.Size(
      frame.rotatedWidth.toDouble(),
      frame.rotatedHeight.toDouble(),
    );

    final detSw = Stopwatch()..start();
    final detection = await engine.detect(frame);
    detSw.stop();
    if (detection == null) return null;

    final ocrSw = Stopwatch()..start();
    final ocr = await engine.recognize(frame, detection.box);
    ocrSw.stop();

    String? plate;
    if (ocr != null &&
        ocr.confidence >= _config.ocrMinConfidence &&
        ocr.text.length >= _config.ocrMinLength) {
      plate = ocr.text;
    }

    return AnprResult(
      plateNumber: plate,
      ocrConfidence: ocr?.confidence ?? 0,
      detectionConfidence: detection.confidence,
      box: detection.box,
      frameSize: frameSize,
      timestamp: DateTime.now(),
      isConfirmed: plate != null,
      detectionMs: detSw.elapsedMicroseconds / 1000.0,
      ocrMs: ocrSw.elapsedMicroseconds / 1000.0,
    );
  }

  /// Convenience wrapper around [recognizeImage] for a file on disk.
  Future<AnprResult?> recognizeImageFile(File file) async =>
      recognizeImage(await file.readAsBytes());

  Future<FrameData> _decodeToFrame(Uint8List bytes) async {
    ui.Codec codec;
    try {
      codec = await ui.instantiateImageCodec(bytes);
    } catch (e) {
      throw AnprException(
        AnprErrorCode.invalidImage,
        'The image could not be decoded.',
        cause: e,
      );
    }
    try {
      final frameInfo = await codec.getNextFrame();
      final image = frameInfo.image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) {
          throw const AnprException(
            AnprErrorCode.invalidImage,
            'The image could not be decoded.',
          );
        }
        return FrameData.fromRgba(
          width: image.width,
          height: image.height,
          rgba: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      } finally {
        image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  /// Releases the native models. Call [initialize] again to reuse the SDK.
  Future<void> dispose() async {
    final engine = _engine;
    _engine = null;
    status.value = AnprSdkStatus.uninitialized;
    await engine?.close();
  }
}
