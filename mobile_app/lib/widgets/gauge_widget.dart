import 'package:flutter/material.dart';
import 'dart:math' as math;

class GaugeWidget extends StatelessWidget {
  final String title;
  final double percentage; // 0.0 to 100.0
  final String valueText;
  final Color color;

  const GaugeWidget({
    super.key,
    required this.title,
    required this.percentage,
    required this.valueText,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 80,
          height: 80,
          child: Stack(
            alignment: Alignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: percentage / 100.0),
                duration: const Duration(milliseconds: 500),
                builder: (context, value, child) {
                  return CustomPaint(
                    size: const Size(80, 80),
                    painter: _GaugePainter(value, color, Theme.of(context).colorScheme.surfaceContainerHighest),
                  );
                },
              ),
              Text(
                valueText,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Text(
          title,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double progress;
  final Color activeColor;
  final Color backgroundColor;

  _GaugePainter(this.progress, this.activeColor, this.backgroundColor);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;
    final strokeWidth = 8.0;

    final bgPaint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    // Draw background arc (240 degrees)
    const startAngle = 150 * math.pi / 180;
    const sweepAngle = 240 * math.pi / 180;
    
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      bgPaint,
    );

    // Draw active arc
    final activeSweepAngle = sweepAngle * progress.clamp(0.0, 1.0);
    if (activeSweepAngle > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        startAngle,
        activeSweepAngle,
        false,
        activePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter oldDelegate) {
    return oldDelegate.progress != progress || 
           oldDelegate.activeColor != activeColor ||
           oldDelegate.backgroundColor != backgroundColor;
  }
}