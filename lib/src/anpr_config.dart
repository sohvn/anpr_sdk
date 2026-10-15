/// Tuning options. Every field has a sensible default, so most apps never
/// need to create one.
class AnprSdkConfig {
  /// Minimum YOLO confidence to accept a plate box.
  final double detectionThreshold;

  /// Minimum gap between two detection runs.
  final Duration detectionInterval;

  /// Minimum gap between two OCR runs.
  final Duration ocrInterval;

  /// OCR reads below this confidence are ignored.
  final double ocrMinConfidence;

  /// OCR reads shorter than this are ignored.
  final int ocrMinLength;

  /// Keep the box on screen this long if one frame misses.
  final Duration boxGrace;

  /// Clear the plate text if no plate was seen for this long.
  final Duration textClear;

  /// Window used to vote between noisy OCR reads.
  final Duration voteWindow;

  /// Max number of recent reads kept for voting.
  final int voteMaxReads;

  /// How many times the same plate must be read before it is "confirmed"
  /// and reported through onPlate / AnprScanner.plates.
  final int confirmReads;

  /// A plate that stays in view is reported again only after this long.
  /// A plate that leaves the view and comes back is reported again at once.
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
  }) : assert(confirmReads >= 1),
       assert(confirmReads <= voteMaxReads);
}

/// Model/pipeline constants. These must match the trained models, so they are
/// not user-configurable and not exported from the package.
class AnprInternals {
  AnprInternals._();

  static const String modelVersion = 'v1.0.0';

  static const String _releaseBase =
      'https://github.com/sohvn/anpr_sdk/releases/download/v1.0.2';

  static const String yoloUrl = '$_releaseBase/best.onnx';
  static const String ocrUrl = '$_releaseBase/anpr_ocr_f16.onnx';
  static const String dictUrl = '$_releaseBase/en_dict.txt';

  static const String yoloFileName = 'best.onnx';
  static const String ocrFileName = 'anpr_ocr_f16.onnx';
  static const String dictFileName = 'en_dict.txt';

  static const int yoloSize = 640;
  static const int plateClassId = 0;

  static const int ocrHeight = 48;
  static const int ocrMaxWidth = 320;
  static const int ocrClasses = 64;

  /// Value written to the padded (unused) right side of the OCR tensor.
  static const double ocrPadValue = -1.0;

  /// Extra margin around the detected box before OCR (fraction of box size).
  static const double cropPadding = 0.06;
}
