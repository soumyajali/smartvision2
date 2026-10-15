import 'package:flutter/material.dart';

import '../core/constants/app_colors.dart';
import '../models/detection_result.dart';

/// Draws detection boxes. Boxes are normalised (0..1) to the upright image,
/// so this overlay must be laid out exactly on top of that image (same size,
/// no cropping) — see [DetectionFrame].
class DetectionOverlay extends StatelessWidget {
  const DetectionOverlay({
    super.key,
    required this.detections,
    this.mirrored = false,
    this.boxColor,
  });

  final List<DetectionResult> detections;
  final bool mirrored;
  final Color? boxColor;

  @override
  Widget build(BuildContext context) {
    if (detections.isEmpty) return const SizedBox.expand();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: DetectionBoxPainter(
          detections: detections,
          primaryColor: boxColor ?? AppColors.accentCyan,
          mirrored: mirrored,
        ),
      ),
    );
  }
}

/// Lays out [child] (camera preview or still image) at [aspectRatio] inside
/// the available space without cropping, and paints [detections] over it.
class DetectionFrame extends StatelessWidget {
  const DetectionFrame({
    super.key,
    required this.aspectRatio,
    required this.child,
    required this.detections,
    this.mirrored = false,
    this.overlays = const [],
  });

  final double aspectRatio;
  final Widget child;
  final List<DetectionResult> detections;
  final bool mirrored;
  final List<Widget> overlays;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: AspectRatio(
        aspectRatio: aspectRatio > 0 ? aspectRatio : 3 / 4,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            DetectionOverlay(detections: detections, mirrored: mirrored),
            ...overlays,
          ],
        ),
      ),
    );
  }
}

class DetectionBoxPainter extends CustomPainter {
  DetectionBoxPainter({
    required this.detections,
    required this.primaryColor,
    this.mirrored = false,
  });

  final List<DetectionResult> detections;
  final Color primaryColor;
  final bool mirrored;

  static const Color hazardColor = Color(0xFFFF4D5E);

  @override
  void paint(Canvas canvas, Size size) {
    final tagBgPaint = Paint()
      ..color = AppColors.primaryBackground.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;

    for (final detection in detections) {
      final box = detection.boundingBox;
      var left = box.left;
      var right = box.right;
      if (mirrored) {
        left = 1 - box.right;
        right = 1 - box.left;
      }
      final rect = Rect.fromLTRB(
        left.clamp(0.0, 1.0).toDouble() * size.width,
        box.top.clamp(0.0, 1.0).toDouble() * size.height,
        right.clamp(0.0, 1.0).toDouble() * size.width,
        box.bottom.clamp(0.0, 1.0).toDouble() * size.height,
      );
      if (rect.width <= 1 || rect.height <= 1) continue;

      final color = detection.isHazard ? hazardColor : primaryColor;
      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = detection.isHazard ? 2.6 : 2.0;
      final fillPaint = Paint()
        ..color = color.withValues(alpha: 0.08)
        ..style = PaintingStyle.fill;
      final cornerPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.2
        ..strokeCap = StrokeCap.round;

      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
      canvas.drawRRect(rrect, fillPaint);
      canvas.drawRRect(rrect, boxPaint);

      final corner = (rect.shortestSide * 0.18).clamp(6.0, 20.0).toDouble();
      void cornerLines(Offset a, Offset b, Offset c) {
        canvas.drawLine(a, b, cornerPaint);
        canvas.drawLine(b, c, cornerPaint);
      }

      cornerLines(Offset(rect.left, rect.top + corner), rect.topLeft,
          Offset(rect.left + corner, rect.top));
      cornerLines(Offset(rect.right - corner, rect.top), rect.topRight,
          Offset(rect.right, rect.top + corner));
      cornerLines(Offset(rect.left, rect.bottom - corner), rect.bottomLeft,
          Offset(rect.left + corner, rect.bottom));
      cornerLines(Offset(rect.right - corner, rect.bottom), rect.bottomRight,
          Offset(rect.right, rect.bottom - corner));

      // A negative confidence means the source has no score (e.g. ML Kit
      // face boxes); never print an invented percentage.
      final percentage = detection.confidence < 0
          ? ''
          : ' ${(detection.confidence * 100).toStringAsFixed(0)}%';
      final labelText = detection.isHazard
          ? '⚠ ${detection.label.toUpperCase()}$percentage'
          : '${detection.label}$percentage';
      final textPainter = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(
            color: detection.isHazard
                ? const Color(0xFFFFB3BA)
                : AppColors.primaryText,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: size.width - 8);

      final tagHeight = textPainter.height + 6;
      final tagWidth = textPainter.width + 12;
      final tagTop = rect.top - tagHeight >= 0 ? rect.top - tagHeight : rect.top;
      final tagLeft = rect.left
          .clamp(0.0, (size.width - tagWidth).clamp(0.0, size.width))
          .toDouble();
      final tagRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(tagLeft, tagTop, tagWidth, tagHeight),
        const Radius.circular(5),
      );
      canvas.drawRRect(tagRect, tagBgPaint);
      canvas.drawRRect(
        tagRect,
        Paint()
          ..color = color.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      textPainter.paint(canvas, Offset(tagLeft + 6, tagTop + 3));
    }
  }

  @override
  bool shouldRepaint(covariant DetectionBoxPainter oldDelegate) {
    return oldDelegate.detections != detections ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.mirrored != mirrored;
  }
}
