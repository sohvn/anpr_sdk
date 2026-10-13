import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

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

/// The ONNX pipeline: YOLO plate detection + CTC OCR.
/// No camera, no UI, no timing logic. Works on any [FrameData].
class AnprEngine {
  final OrtSession _yolo;
  final OrtSession _ocr;
  final List<String> _chars;
  final AnprSdkConfig _config;

  int _inflight = 0;
  bool _closed = false;

  AnprEngine._(this._yolo, this._ocr, this._chars, this._config);

  static Future<AnprEngine> create(
    ModelFiles files,
    AnprSdkConfig config,
  ) async {
    final runtime = OnnxRuntime();
    final yolo = await runtime.createSession(files.yoloPath);
    OrtSession? ocr;
    try {
      ocr = await runtime.createSession(files.ocrPath);

      final dictionary = await File(files.dictPath).readAsString();
      final lines = dictionary
          .split(RegExp(r'\r?\n'))
          .where((l) => l.isNotEmpty)
          .toList();
      final chars = ['blank', ...lines, ' '];

      if (chars.length != AnprInternals.ocrClasses) {
        throw AnprException(
          AnprErrorCode.modelSetupFailed,
          'OCR dictionary error: expected ${AnprInternals.ocrClasses} '
          'classes, got ${chars.length}',
        );
      }

      return AnprEngine._(yolo, ocr, chars, config);
    } catch (_) {
      try {
        await yolo.close();
        await ocr?.close();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    // Let any in-flight frame finish before closing native sessions.
    for (int i = 0; i < 40 && _inflight > 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      await _yolo.close();
      await _ocr.close();
    } catch (_) {}
  }

  // ============================================================
  // YOLO
  // ============================================================

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

    // Preprocessing runs off the UI thread.
    final data = await buildYoloInputAsync(frame, lb);

    final input = await OrtValue.fromList(data, [
      1,
      3,
      AnprInternals.yoloSize,
      AnprInternals.yoloSize,
    ]);

    try {
      final outputs = await _yolo.run({_yolo.inputNames.first: input});
      try {
        final output = outputs[_yolo.outputNames.first];
        if (output == null) return null;

        // End-to-end (NMS-free) output: [1, N, 6] = x1,y1,x2,y2,conf,class
        final shape = output.shape;
        if (shape.length != 3 || shape[2] != 6) {
          throw Exception('Expected YOLO [1,N,6], got $shape');
        }
        final n = shape[1];
        final values = await output.asFlattenedList();

        PlateDetection? best;

        for (int i = 0; i < n; i++) {
          final base = i * 6;
          final confidence = (values[base + 4] as num).toDouble();
          final classId = (values[base + 5] as num).toDouble().round();

          if (classId != AnprInternals.plateClassId) continue;
          if (confidence < _config.detectionThreshold) continue;
          if (best != null && confidence <= best.confidence) continue;

          final x1 = (values[base + 0] as num).toDouble();
          final y1 = (values[base + 1] as num).toDouble();
          final x2 = (values[base + 2] as num).toDouble();
          final y2 = (values[base + 3] as num).toDouble();

          final left = ((x1 - lb.padX) / lb.scale).clamp(0.0, srcW.toDouble());
          final top = ((y1 - lb.padY) / lb.scale).clamp(0.0, srcH.toDouble());
          final right = ((x2 - lb.padX) / lb.scale).clamp(0.0, srcW.toDouble());
          final bottom =
              ((y2 - lb.padY) / lb.scale).clamp(0.0, srcH.toDouble());

          if (right - left < 4 || bottom - top < 4) continue;

          best = PlateDetection(
            box: Rect.fromLTRB(left, top, right, bottom),
            confidence: confidence,
          );
        }

        return best;
      } finally {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
    } finally {
      await input.dispose();
    }
  }

  // ============================================================
  // OCR
  // ============================================================

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

    final input = await OrtValue.fromList(data, [
      1,
      3,
      AnprInternals.ocrHeight,
      AnprInternals.ocrMaxWidth,
    ]);

    try {
      final outputs = await _ocr.run({_ocr.inputNames.first: input});
      try {
        final output = outputs[_ocr.outputNames.first];
        if (output == null) return null;

        final shape = output.shape;
        if (shape.length != 3 || shape[2] != _chars.length) {
          throw Exception('Expected OCR [1,T,${_chars.length}], got $shape');
        }

        final steps = shape[1];
        final classes = shape[2];
        final values = await output.asFlattenedList();

        // Detect whether the model output is already softmaxed.
        double firstSum = 0;
        for (int c = 0; c < classes; c++) {
          firstSum += (values[c] as num).toDouble();
        }
        final isProb = (firstSum - 1.0).abs() < 0.02;

        final text = StringBuffer();
        double confSum = 0;
        int confCount = 0;
        int previous = -1;

        for (int t = 0; t < steps; t++) {
          int bestIndex = 0;
          double bestValue = -double.infinity;

          for (int c = 0; c < classes; c++) {
            final v = (values[t * classes + c] as num).toDouble();
            if (v > bestValue) {
              bestValue = v;
              bestIndex = c;
            }
          }

          double prob = bestValue;
          if (!isProb) {
            double denom = 0;
            for (int c = 0; c < classes; c++) {
              denom += math.exp(
                (values[t * classes + c] as num).toDouble() - bestValue,
              );
            }
            prob = 1.0 / denom;
          }

          // CTC collapse
          if (bestIndex != 0 && bestIndex != previous) {
            text.write(_chars[bestIndex]);
            confSum += prob;
            confCount++;
          }
          previous = bestIndex;
        }

        final plate = text
            .toString()
            .toUpperCase()
            .replaceAll(RegExp(r'[^A-Z0-9]'), '');

        if (plate.isEmpty || confCount == 0) return null;

        return OcrResult(text: plate, confidence: confSum / confCount);
      } finally {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
    } finally {
      await input.dispose();
    }
  }
}
