import 'package:flutter/material.dart';

class TemperatureCard extends StatelessWidget {
  final String title;
  final double? temperature;
  final IconData icon;

  const TemperatureCard({
    super.key,
    required this.title,
    this.temperature,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    Color tempColor = theme.colorScheme.primary;
    if (temperature != null) {
      if (temperature! >= 85) {
        tempColor = theme.colorScheme.error;
      } else if (temperature! >= 75) {
        tempColor = Colors.orange;
      } else {
        tempColor = Colors.green;
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tempColor.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: tempColor,
              size: 24,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  temperature != null ? '${temperature!.toStringAsFixed(0)}°C' : 'N/A',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: tempColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}