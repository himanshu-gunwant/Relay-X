import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/hardware_provider.dart';
import '../widgets/gauge_widget.dart';
import '../widgets/temperature_card.dart';
import 'package:intl/intl.dart';

class HardwareScreen extends StatelessWidget {
  const HardwareScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('System Monitor'),
        actions: const [
          _LastUpdatedHeader(),
        ],
      ),
      body: const _HardwareBody(),
    );
  }
}

class _LastUpdatedHeader extends ConsumerWidget {
  const _LastUpdatedHeader();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final telemetryAsync = ref.watch(hardwareTelemetryProvider);
    
    return telemetryAsync.when(
      data: (data) => Padding(
        padding: const EdgeInsets.only(right: 16.0),
        child: Center(
          child: Text(
            'Last updated: ${DateFormat('HH:mm:ss').format(DateTime.fromMillisecondsSinceEpoch(data.timestamp))}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
    );
  }
}

class _HardwareBody extends ConsumerWidget {
  const _HardwareBody();

  String _shortenGpuName(String name) {
    // "NVIDIA GeForce RTX 4060 Laptop GPU" -> "RTX 4060"
    final rtxMatch = RegExp(r'(RTX|GTX)\s*\d+\s*\w*').firstMatch(name);
    if (rtxMatch != null) return rtxMatch.group(0)!.trim();
    // Fallback: remove "NVIDIA GeForce" prefix
    return name
        .replaceAll('NVIDIA GeForce ', '')
        .replaceAll('Laptop GPU', '')
        .trim();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final telemetryAsync = ref.watch(hardwareTelemetryProvider);

    return telemetryAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text('Failed to connect to hardware monitor', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(error.toString(), style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      data: (data) {
        final gpuShortName = _shortenGpuName(data.gpu.name);
        
        return RefreshIndicator(
          onRefresh: () async {},
          child: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              // Gauges Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  GaugeWidget(
                    title: 'CPU Load',
                    percentage: data.cpu.usagePercent,
                    valueText: '${data.cpu.usagePercent.toStringAsFixed(1)}%',
                    color: Colors.blueAccent,
                  ),
                  GaugeWidget(
                    title: 'Memory',
                    percentage: data.ram.usagePercent,
                    valueText: '${data.ram.usagePercent.toStringAsFixed(0)}%',
                    color: Colors.purpleAccent,
                  ),
                  if (data.gpu.usagePercent != null)
                    GaugeWidget(
                      title: gpuShortName,
                      percentage: data.gpu.usagePercent!,
                      valueText: '${data.gpu.usagePercent!.toStringAsFixed(0)}%',
                      color: Colors.greenAccent,
                    ),
                ],
              ),
              const SizedBox(height: 32),

              // Temperatures
              if (data.cpu.temperatureCelsius != null || data.gpu.temperatureCelsius != null) ...[
                Text(
                  'Temperatures',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    if (data.cpu.temperatureCelsius != null)
                      Expanded(
                        child: TemperatureCard(
                          title: 'CPU Package',
                          temperature: data.cpu.temperatureCelsius,
                          icon: Icons.memory,
                        ),
                      ),
                    if (data.cpu.temperatureCelsius != null && data.gpu.temperatureCelsius != null)
                      const SizedBox(width: 16),
                    if (data.gpu.temperatureCelsius != null)
                      Expanded(
                        child: TemperatureCard(
                          title: gpuShortName,
                          temperature: data.gpu.temperatureCelsius,
                          icon: Icons.developer_board,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 32),
              ],
              
              // VRAM usage bar
              if (data.gpu.vramTotalMb > 0 && data.gpu.vramUsedMb != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.storage, size: 18, color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(
                            'VRAM Usage',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            '${(data.gpu.vramUsedMb! / 1024).toStringAsFixed(1)} / ${(data.gpu.vramTotalMb / 1024).toStringAsFixed(1)} GB',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: data.gpu.vramUsedMb! / data.gpu.vramTotalMb,
                          minHeight: 8,
                          backgroundColor: theme.colorScheme.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            data.gpu.vramUsedMb! / data.gpu.vramTotalMb > 0.8
                                ? Colors.redAccent
                                : Colors.greenAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }
}