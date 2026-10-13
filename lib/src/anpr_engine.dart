import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter_litert/flutter_litert.dart';

import 'anpr_config.dart';
import 'anpr_exception.dart';
import 'frame_processing.dart';
import 'model_manager.dart';

class PlateDetection {
  final Rect box;
  final double confidence;
  const PlateDetection({required this.box, required this.confidence});
}

class OcrResult {
  final String text;
  final double confidence;
  const OcrResult({required this.text, required this.confidence});
}

/// On-device TFLite pipeline using the supplied YOLO26 plate detector and
/// PP-OCRv5 CTC recognizer. The interpreter inputs are NHWC, matching the
/// supplied Python reference implementation.
class AnprEngine {
  final Interpreter _detector;
  final Interpreter _recognizer;
  final List<String> _chars;
  final AnprSdkConfig _config;

  int _inflight = 0;
  bool _closed = false;

  AnprEngine._(this._detector, this._recognizer, this._chars, this._config);

  static Future<AnprEngine> create(
    ModelFiles files,
    AnprSdkConfig config,
  ) async {
    Interpreter? detector;
    Interpreter? recognizer;
    try {
      detector = await Interpreter.fromAsset(files.detectorPath);
      recognizer = await Interpreter.fromAsset(files.recognitionPath);
      detector.allocateTensors();
      recognizer.allocateTensors();

      final detInput = detector.getInputTensor(0);
      final recInput = recognizer.getInputTensor(0);
      if (!_shapeEquals(detInput.shape, const [1, 960, 960, 3])) {
        throw AnprException(
          AnprErrorCode.modelSetupFailed,
          'Unexpected detector input shape ${detInput.shape}; expected [1,960,960,3].',
        );
      }
      if (!_shapeEquals(recInput.shape, const [1, 48, 320, 3])) {
        throw AnprException(
          AnprErrorCode.modelSetupFailed,
          'Unexpected recognition input shape ${recInput.shape}; expected [1,48,320,3].',
        );
      }

      final outputShapes = List.generate(
        detector.getOutputTensors().length,
        (i) => detector!.getOutputTensor(i).shape,
      );
      if (!outputShapes.any((s) => s.isNotEmpty && s.last == 4) ||
          !outputShapes.any((s) => s.isNotEmpty && s.last == 1)) {
        throw AnprException(
          AnprErrorCode.modelSetupFailed,
          'Detector outputs $outputShapes do not match expected box and score tensors.',
        );
      }

      final recShape = recognizer.getOutputTensor(0).shape;
      if (recShape.length != 3 || recShape.last != AnprInternals.ocrClasses) {
        throw AnprException(
          AnprErrorCode.modelSetupFailed,
          'Unexpected recognition output shape $recShape; expected [1,T,64].',
        );
      }

      const charset = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
      final chars = <String>['blank', ...charset.split(''), ' '];
      if (chars.length != AnprInternals.ocrClasses) {
        throw const AnprException(
          AnprErrorCode.modelSetupFailed,
          'The built-in OCR character set does not match the model.',
        );
      }
      return AnprEngine._(detector, recognizer, chars, config);
    } catch (_) {
      detector?.close();
      recognizer?.close();
      rethrow;
    }
  }

  static bool _shapeEquals(List<int> actual, List<int> expected) {
    if (actual.length != expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  Future<void> close() async {
    _closed = true;
    for (var i = 0; i < 40 && _inflight > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    _detector.close();
    _recognizer.close();
  }

  static void _setFloatInput(Tensor tensor, Float32List values) {
    final bytes = values.buffer.asUint8List(
      values.offsetInBytes,
      values.lengthInBytes,
    );
    if (tensor.data.lengthInBytes != bytes.length) {
      throw StateError(
        'Input tensor expects ${tensor.data.lengthInBytes} bytes, got ${bytes.length}.',
      );
    }
    tensor.data.setRange(0, bytes.length, bytes);
  }

  static Float32List _readFloatTensor(Tensor tensor) {
    final data = tensor.data;
    if (data.lengthInBytes % 4 != 0) {
      throw StateError('Expected a float32 output tensor, got an invalid byte length.');
    }
    return Float32List.view(
      data.buffer,
      data.offsetInBytes,
      data.lengthInBytes ~/ 4,
    );
  }

  // -----------------------------------------------------------------------
  // Plate detection
  // -----------------------------------------------------------------------

  Future<PlateDetection?> detect(FrameData frame) async {
    if (_closed) return null;
    _inflight++;
    try {
      return await _detect(frame);
    } finally {
      _inflight--;
    }
  }

  Future<PlateDetection?> _detect(FrameData frame) async {
    final srcW = frame.rotatedWidth;
    final srcH = frame.rotatedHeight;
    final lb = Letterbox.of(srcW, srcH, AnprInternals.yoloSize);
    final data = await buildYoloInputAsync(frame, lb);
    _setFloatInput(_detector.getInputTensor(0), data);
    _detector.invoke();

    Tensor? boxesTensor;
    Tensor? scoresTensor;
    for (final tensor in _detector.getOutputTensors()) {
      if (tensor.shape.isNotEmpty && tensor.shape.last == 4) {
        boxesTensor = tensor;
      } else if (tensor.shape.isNotEmpty && tensor.shape.last == 1) {
        scoresTensor = tensor;
      }
    }
    if (boxesTensor == null || scoresTensor == null) {
      throw StateError('Detector must expose boxes [1,N,4] and scores [1,N,1].');
    }

    final boxes = _readFloatTensor(boxesTensor);
    final scores = _readFloatTensor(scoresTensor);
    final n = math.min(boxes.length ~/ 4, scores.length);
    PlateDetection? best;

    for (var i = 0; i < n; i++) {
      final confidence = scores[i];
      if (!confidence.isFinite || confidence < _config.detectionThreshold) {
        continue;
      }

      // The supplied Python pipeline reports normalized xyxy coordinates.
      final x1 = boxes[i * 4] * AnprInternals.yoloSize;
      final y1 = boxes[i * 4 + 1] * AnprInternals.yoloSize;
      final x2 = boxes[i * 4 + 2] * AnprInternals.yoloSize;
      final y2 = boxes[i * 4 + 3] * AnprInternals.yoloSize;

      final left = ((x1 - lb.padX) / lb.scale).clamp(0.0, srcW.toDouble()).toDouble();
      final top = ((y1 - lb.padY) / lb.scale).clamp(0.0, srcH.toDouble()).toDouble();
      final right = ((x2 - lb.padX) / lb.scale).clamp(0.0, srcW.toDouble()).toDouble();
      final bottom = ((y2 - lb.padY) / lb.scale).clamp(0.0, srcH.toDouble()).toDouble();
      if (right - left < 4 || bottom - top < 4) continue;
      if (best != null && confidence <= best.confidence) continue;

      best = PlateDetection(
        box: Rect.fromLTRB(left, top, right, bottom),
        confidence: confidence.clamp(0.0, 1.0).toDouble(),
      );
    }
    return best;
  }

  // -----------------------------------------------------------------------
  // CTC plate recognition
  // -----------------------------------------------------------------------

  Future<OcrResult?> recognize(FrameData frame, Rect box) async {
    if (_closed) return null;
    _inflight++;
    try {
      return await _recognize(frame, box);
    } finally {
      _inflight--;
    }
  }

  Future<OcrResult?> _recognize(FrameData frame, Rect box) async {
    final data = await buildOcrInputAsync(frame, box);
    if (data == null) return null;
    _setFloatInput(_recognizer.getInputTensor(0), data);
    _recognizer.invoke();

    final tensor = _recognizer.getOutputTensor(0);
    final shape = tensor.shape;
    if (shape.length != 3 || shape.last != _chars.length) {
      throw StateError('Unexpected OCR output shape $shape.');
    }
    final values = _readFloatTensor(tensor);
    final steps = shape[1];
    final classes = shape[2];

    var firstSum = 0.0;
    for (var c = 0; c < classes; c++) {
      firstSum += values[c];
    }
    final isProbabilities = (firstSum - 1.0).abs() < 0.02;

    final text = StringBuffer();
    var confidenceSum = 0.0;
    var confidenceCount = 0;
    var previous = -1;

    for (var t = 0; t < steps; t++) {
      var bestIndex = 0;
      var bestValue = -double.infinity;
      for (var c = 0; c < classes; c++) {
        final value = values[t * classes + c];
        if (value > bestValue) {
          bestValue = value;
          bestIndex = c;
        }
      }

      var probability = bestValue;
      if (!isProbabilities) {
        var denominator = 0.0;
        for (var c = 0; c < classes; c++) {
          denominator += math.exp(values[t * classes + c] - bestValue);
        }
        probability = denominator == 0 ? 0 : 1.0 / denominator;
      }

      // CTC greedy collapse: remove blanks and repeated adjacent symbols.
      if (bestIndex != 0 && bestIndex != previous) {
        final character = _chars[bestIndex];
        if (character != ' ') text.write(character);
        confidenceSum += probability.clamp(0.0, 1.0).toDouble();
        confidenceCount++;
      }
      previous = bestIndex;
    }

    final plate = text.toString().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (plate.isEmpty || confidenceCount == 0) return null;
    return OcrResult(
      text: plate,
      confidence: (confidenceSum / confidenceCount).clamp(0.0, 1.0).toDouble(),
    );
  }
}
