import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Keeps the delivery stamp beside the last text line, widening when possible.
class TelegramStampedText extends StatelessWidget {
  const TelegramStampedText({
    super.key,
    required this.text,
    required this.stamp,
    required this.stampWidth,
  });
  final TextSpan text;
  final Widget stamp;
  final double stampWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final reserved = scaler.scale(stampWidth);
      final painter = TextPainter(
        text: text,
        textDirection: Directionality.of(context),
        textScaler: scaler,
        textWidthBasis: TextWidthBasis.longestLine,
      );
      var textWidth = constraints.maxWidth;
      painter.layout(maxWidth: textWidth);
      var lines = painter.computeLineMetrics();
      if (lines.isNotEmpty &&
          lines.last.width + reserved > constraints.maxWidth) {
        textWidth = math.max(1.0, constraints.maxWidth - reserved);
        painter.layout(maxWidth: textWidth);
        lines = painter.computeLineMetrics();
      }
      final width = math.min(
        constraints.maxWidth,
        math.max(
          painter.width,
          (lines.isEmpty ? 0 : lines.last.width) + reserved,
        ),
      );
      final height = math.max(painter.height, scaler.scale(16));
      painter.dispose();
      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            SizedBox(
              width: math.min(textWidth, width),
              child: RichText(
                text: text,
                textScaler: scaler,
                textWidthBasis: TextWidthBasis.longestLine,
              ),
            ),
            Positioned(right: 0, bottom: 0, child: stamp),
          ],
        ),
      );
    },
  );
}
