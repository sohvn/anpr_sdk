/// Tuning options for the on-device ANPR pipeline.
///
/// Both TFLite models are bundled with this Flutter package. Initialization
/// does not download models, require an API token, or need network access.
class AnprSdkConfig {
  final double detectionThreshold;
  final Duration detectionInterval;
  final Duration ocrInterval;
  final double ocrMinConfidence;
  final int ocrMinLength;
  final Duration boxGrace;
  final Duration textClear;
  final Duration voteWindow;
  final int voteMaxReads;
  final int confirmReads;
  final Duration repeatCooldown;

  const AnprSdkConfig({
    this.detectionThreshold = 0.35,
    this.detectionInterval = const Duration(milliseconds: 150),
    this.ocrInterval = const Duration(milliseconds: 400),
    this.ocrMinConfidence = 0.55,
    this.ocrMinLength = 3,
    this.boxGrace = const Duration(milliseconds: 500),
    this.textClear = const Duration(seconds: 3),
    this.voteWindow = const Duration(milliseconds: 2500),
    this.voteMaxReads = 7,
    this.confirmReads = 2,
    this.repeatCooldown = const Duration(seconds: 5),
  })  : assert(confirmReads >= 1),
        assert(confirmReads <= voteMaxReads);

  /// Model dimensions and preprocessing constants for the supplied models.
  static const int detectorSize = 960;
  static const int ocrHeight = 48;
  static const int ocrMaxWidth = 320;
  static const int ocrClasses = 64;
  static const double ocrPadValue = -1.0;
  static const double cropPadding = 0.0;
}

/// Internal fixed dimensions for the bundled TFLite models.
class AnprInternals {
  AnprInternals._();
  static const int yoloSize = 960;
  static const int plateClassId = 0;
  static const int ocrHeight = 48;
  static const int ocrMaxWidth = 320;
  static const int ocrClasses = 64;
  static const double ocrPadValue = -1.0;
  static const double cropPadding = 0.0;

  /// Package asset paths. These are resolved by Flutter's asset bundle.
  static const String detectorAsset =
      'packages/anpr_sdk/assets/models/plate_det_int8_dynamic.tflite';
  static const String recognitionAsset =
      'packages/anpr_sdk/assets/models/plate_rec_float16.tflite';
}
