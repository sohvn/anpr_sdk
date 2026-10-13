import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';

import 'anpr_config.dart';

// ============================================================
// FRAME DATA (sendable to isolates, no `image` package needed)
// ============================================================

const int _fmtYuv3 = 0; // Android yuv420 (3 planes)
const int _fmtNv12 = 1; // 2 planes (interleaved UV)
const int _fmtBgra = 2; // iOS bgra8888
const int _fmtRgba = 3; // decoded still image

class FrameData {
  final int width;
  final int height;
  final int rotation; // 0, 90, 180, 270 (clockwise, to upright)
  final int format;
  final Uint8List p0;
  final Uint8List p1;
  final Uint8List p2;
  final int s0;
  final int s1;
  final int s2;
  final int ps1;
  final int ps2;

  FrameData({
    required this.width,
    required this.height,
    required this.rotation,
    required this.format,
    required this.p0,
    required this.p1,
    required this.p2,
    required this.s0,
    required this.s1,
    required this.s2,
    required this.ps1,
    required this.ps2,
  });

  factory FrameData.fromCameraImage(CameraImage image, int rotation) {
    final planes = image.planes;
    final empty = Uint8List(0);

    int format;
    if (planes.length == 1) {
      format = _fmtBgra;
    } else if (planes.length == 2) {
      format = _fmtNv12;
    } else {
      format = _fmtYuv3;
    }

    return FrameData(
      width: image.width,
      height: image.height,
      rotation: rotation % 360,
      format: format,
      p0: planes[0].bytes,
      p1: planes.length > 1 ? planes[1].bytes : empty,
      p2: planes.length > 2 ? planes[2].bytes : empty,
      s0: planes[0].bytesPerRow,
      s1: planes.length > 1 ? planes[1].bytesPerRow : 0,
      s2: planes.length > 2 ? planes[2].bytesPerRow : 0,
      ps1: planes.length > 1 ? (planes[1].bytesPerPixel ?? 1) : 1,
      ps2: planes.length > 2 ? (planes[2].bytesPerPixel ?? 1) : 1,
    );
  }

  /// A decoded still image (tightly packed RGBA, already upright).
  factory FrameData.fromRgba({
    required int width,
    required int height,
    required Uint8List rgba,
  }) {
    return FrameData(
      width: width,
      height: height,
      rotation: 0,
      format: _fmtRgba,
      p0: rgba,
      p1: Uint8List(0),
      p2: Uint8List(0),
      s0: width * 4,
      s1: 0,
      s2: 0,
      ps1: 1,
      ps2: 1,
    );
  }

  bool get _swap => rotation == 90 || rotation == 270;
  int get rotatedWidth => _swap ? height : width;
  int get rotatedHeight => _swap ? width : height;

  /// Packed 0xRRGGBB at a source-frame pixel.
  int _rgbAt(int sx, int sy) {
    if (format == _fmtBgra) {
      final i = sy * s0 + sx * 4;
      return (p0[i + 2] << 16) | (p0[i + 1] << 8) | p0[i];
    }
    if (format == _fmtRgba) {
      final i = sy * s0 + sx * 4;
      return (p0[i] << 16) | (p0[i + 1] << 8) | p0[i + 2];
    }

    final y = p0[sy * s0 + sx];
    final uvY = sy >> 1;
    final uvX = sx >> 1;

    int u;
    int v;
    if (format == _fmtNv12) {
      final i = uvY * s1 + uvX * 2;
      u = p1[i];
      v = p1[i + 1];
    } else {
      u = p1[uvY * s1 + uvX * ps1];
      v = p2[uvY * s2 + uvX * ps2];
    }

    final ud = u - 128;
    final vd = v - 128;

    int r = y + ((1436 * vd) >> 10);
    int g = y - ((352 * ud + 731 * vd) >> 10);
    int b = y + ((1814 * ud) >> 10);

    r = r < 0 ? 0 : (r > 255 ? 255 : r);
    g = g < 0 ? 0 : (g > 255 ? 255 : g);
    b = b < 0 ? 0 : (b > 255 ? 255 : b);

    return (r << 16) | (g << 8) | b;
  }

  /// Packed 0xRRGGBB at a pixel of the *rotated (upright)* frame.
  int rgbAtRotated(int rx, int ry) {
    int sx;
    int sy;
    switch (rotation) {
      case 90:
        sx = ry;
        sy = height - 1 - rx;
        break;
      case 180:
        sx = width - 1 - rx;
        sy = height - 1 - ry;
        break;
      case 270:
        sx = width - 1 - ry;
        sy = rx;
        break;
      default:
        sx = rx;
        sy = ry;
    }
    return _rgbAt(sx, sy);
  }
}

class Letterbox {
  final double scale;
  final int padX;
  final int padY;
  final int resizedW;
  final int resizedH;

  const Letterbox(
    this.scale,
    this.padX,
    this.padY,
    this.resizedW,
    this.resizedH,
  );

  factory Letterbox.of(int srcW, int srcH, int size) {
    final scale = math.min(size / srcW, size / srcH);
    final rw = math.max(1, (srcW * scale).round());
    final rh = math.max(1, (srcH * scale).round());
    return Letterbox(scale, (size - rw) ~/ 2, (size - rh) ~/ 2, rw, rh);
  }
}

// ============================================================
// ISOLATE PREPROCESSING
// ============================================================

Future<Float32List> buildYoloInputAsync(FrameData frame, Letterbox lb) {
  return Isolate.run(() => buildYoloInput(frame, lb));
}

Float32List buildYoloInput(FrameData f, Letterbox lb) {
  const size = AnprInternals.yoloSize;
  const plane = size * size;
  final out = Float32List(3 * plane);
  out.fillRange(0, out.length, 114 / 255.0);

  final maxX = f.rotatedWidth - 1;
  final maxY = f.rotatedHeight - 1;
  const inv = 1.0 / 255.0;

  for (int oy = lb.padY; oy < lb.padY + lb.resizedH; oy++) {
    final ry = math.min(maxY, ((oy - lb.padY + 0.5) / lb.scale).floor());
    for (int ox = lb.padX; ox < lb.padX + lb.resizedW; ox++) {
      final rx = math.min(maxX, ((ox - lb.padX + 0.5) / lb.scale).floor());
      final c = f.rgbAtRotated(rx, ry);
      final idx = oy * size + ox;
      out[idx] = ((c >> 16) & 0xFF) * inv;
      out[plane + idx] = ((c >> 8) & 0xFF) * inv;
      out[2 * plane + idx] = (c & 0xFF) * inv;
    }
  }
  return out;
}

Future<Float32List?> buildOcrInputAsync(FrameData frame, Rect box) {
  return Isolate.run(() => buildOcrInput(frame, box));
}

Float32List? buildOcrInput(FrameData f, Rect box) {
  final rw = f.rotatedWidth;
  final rh = f.rotatedHeight;

  final padW = box.width * AnprInternals.cropPadding;
  final padH = box.height * AnprInternals.cropPadding;

  final left = math.max(0.0, box.left - padW);
  final top = math.max(0.0, box.top - padH);
  final right = math.min(rw.toDouble(), box.right + padW);
  final bottom = math.min(rh.toDouble(), box.bottom + padH);

  final cw = right - left;
  final ch = bottom - top;
  if (cw <= 2 || ch <= 2) return null;

  const h = AnprInternals.ocrHeight;
  const maxW = AnprInternals.ocrMaxWidth;
  const plane = h * maxW;

  final newW = math.max(1, math.min(maxW, (cw * h / ch).toInt()));

  final out = Float32List(3 * plane);
  out.fillRange(0, out.length, AnprInternals.ocrPadValue);

  double norm(int v) => ((v / 255.0) - 0.5) / 0.5;

  for (int y = 0; y < h; y++) {
    final sy = top + (y + 0.5) * ch / h - 0.5;
    final y0 = sy.floor().clamp(0, rh - 1);
    final y1 = math.min(rh - 1, y0 + 1);
    final fy = (sy - y0).clamp(0.0, 1.0);

    for (int x = 0; x < newW; x++) {
      final sx = left + (x + 0.5) * cw / newW - 0.5;
      final x0 = sx.floor().clamp(0, rw - 1);
      final x1 = math.min(rw - 1, x0 + 1);
      final fx = (sx - x0).clamp(0.0, 1.0);

      final c00 = f.rgbAtRotated(x0, y0);
      final c10 = f.rgbAtRotated(x1, y0);
      final c01 = f.rgbAtRotated(x0, y1);
      final c11 = f.rgbAtRotated(x1, y1);

      double mix(int shift) {
        final a =
            ((c00 >> shift) & 0xFF) * (1 - fx) + ((c10 >> shift) & 0xFF) * fx;
        final b =
            ((c01 >> shift) & 0xFF) * (1 - fx) + ((c11 >> shift) & 0xFF) * fx;
        return a * (1 - fy) + b * fy;
      }

      final idx = y * maxW + x;
      // Model expects BGR order (trained with cv2.imread).
      out[idx] = norm(mix(0).round()); // B
      out[plane + idx] = norm(mix(8).round()); // G
      out[2 * plane + idx] = norm(mix(16).round()); // R
    }
  }
  return out;
}
