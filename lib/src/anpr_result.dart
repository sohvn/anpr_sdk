import 'dart:ui' show Rect, Size;

/// What the SDK hands back to the app.
///
/// For the live stream ([AnprScanner.live]) fields update every frame.
/// For confirmed plates ([AnprScanner.plates], `onPlate`) [isConfirmed] is true
/// and [plateNumber] is always non-null.
class AnprResult {
  /// Plate text, upper-case letters and digits only (e.g. `MH12AB1234`).
  /// Null when no plate has been read yet.
  final String? plateNumber;

  /// Confidence of the latest OCR read, 0..1.
  final double ocrConfidence;

  /// Confidence of the plate box, 0..1.
  final double detectionConfidence;

  /// Plate box in pixels of the upright frame (see [frameSize]).
  final Rect? box;

  /// Size of the upright frame the [box] refers to.
  final Size frameSize;

  final DateTime timestamp;

  /// True when the same plate was read enough times to be trusted.
  final bool isConfirmed;

  /// Timings, handy for debugging.
  final double detectionMs;
  final double ocrMs;

  const AnprResult({
    this.plateNumber,
    this.ocrConfidence = 0,
    this.detectionConfidence = 0,
    this.box,
    this.frameSize = const Size(1, 1),
    required this.timestamp,
    this.isConfirmed = false,
    this.detectionMs = 0,
    this.ocrMs = 0,
  });

  factory AnprResult.empty() => AnprResult(timestamp: DateTime.now());

  bool get hasPlate => plateNumber != null;

  /// Note: [isConfirmed] is NOT carried over; it resets to false unless given.
  AnprResult copyWith({
    String? plateNumber,
    bool clearPlate = false,
    double? ocrConfidence,
    double? detectionConfidence,
    Rect? box,
    bool clearBox = false,
    Size? frameSize,
    DateTime? timestamp,
    bool? isConfirmed,
    double? detectionMs,
    double? ocrMs,
  }) {
    return AnprResult(
      plateNumber: clearPlate ? null : (plateNumber ?? this.plateNumber),
      ocrConfidence: ocrConfidence ?? this.ocrConfidence,
      detectionConfidence: detectionConfidence ?? this.detectionConfidence,
      box: clearBox ? null : (box ?? this.box),
      frameSize: frameSize ?? this.frameSize,
      timestamp: timestamp ?? this.timestamp,
      isConfirmed: isConfirmed ?? false,
      detectionMs: detectionMs ?? this.detectionMs,
      ocrMs: ocrMs ?? this.ocrMs,
    );
  }

  @override
  String toString() =>
      'AnprResult(plate: $plateNumber, ocr: ${ocrConfidence.toStringAsFixed(2)}, '
      'det: ${detectionConfidence.toStringAsFixed(2)}, confirmed: $isConfirmed)';
}
