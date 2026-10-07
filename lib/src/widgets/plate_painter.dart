import 'dart:math' as math;

import 'package:flutter/material.dart';

class PlatePainter extends CustomPainter {
  final Rect? rect;
  final int imageWidth;
  final int imageHeight;
  final double confidence;
  final Color color;

  PlatePainter({
    required this.rect,
    required this.imageWidth,
    required this.imageHeight,
    required this.confidence,
    this.color = Colors.green,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final box = rect;
    if (box == null || imageWidth <= 0 || imageHeight <= 0) return;

    final scaleX = size.width / imageWidth;
    final scaleY = size.height / imageHeight;

    final mapped = Rect.fromLTRB(
      box.left * scaleX,
      box.top * scaleY,
      box.right * scaleX,
      box.bottom * scaleY,
    );

    canvas.drawRect(
      mapped,
      Paint()
        ..style = PaintingStyle.fill
        ..color = color.withAlpha(38),
    );
    canvas.drawRect(
      mapped,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4.0
        ..color = color,
    );

    final tp = TextPainter(
      text: TextSpan(
        text: 'PLATE ${(confidence * 100).round()}%',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelY = math.max(0.0, mapped.top - tp.height - 6);

    canvas.drawRect(
      Rect.fromLTWH(mapped.left, labelY, tp.width + 12, tp.height + 6),
      Paint()..color = color,
    );
    tp.paint(canvas, Offset(mapped.left + 6, labelY + 3));
  }

  @override
  bool shouldRepaint(covariant PlatePainter old) {
    return old.rect != rect ||
        old.imageWidth != imageWidth ||
        old.imageHeight != imageHeight ||
        old.confidence != confidence ||
        old.color != color;
  }
}
