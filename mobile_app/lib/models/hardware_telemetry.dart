class HardwareTelemetry {
  final CpuTelemetry cpu;
  final GpuTelemetry gpu;
  final RamTelemetry ram;
  final FanTelemetry fans;
  final String? macAddress;
  final int timestamp;

  HardwareTelemetry({
    required this.cpu,
    required this.gpu,
    required this.ram,
    required this.fans,
    this.macAddress,
    required this.timestamp,
  });

  factory HardwareTelemetry.fromJson(Map<String, dynamic> json) {
    return HardwareTelemetry(
      cpu: CpuTelemetry.fromJson(json['cpu'] ?? {}),
      gpu: GpuTelemetry.fromJson(json['gpu'] ?? {}),
      ram: RamTelemetry.fromJson(json['ram'] ?? {}),
      fans: FanTelemetry.fromJson(json['fans'] ?? {}),
      macAddress: json['macAddress'] as String?,
      timestamp: json['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
    );
  }
}

class CpuTelemetry {
  final double usagePercent;
  final double? temperatureCelsius;
  final int coreCount;
  final List<double> perCoreUsage;

  CpuTelemetry({
    required this.usagePercent,
    this.temperatureCelsius,
    required this.coreCount,
    required this.perCoreUsage,
  });

  factory CpuTelemetry.fromJson(Map<String, dynamic> json) {
    return CpuTelemetry(
      usagePercent: (json['usagePercent'] ?? 0).toDouble(),
      temperatureCelsius: json['temperatureCelsius']?.toDouble(),
      coreCount: json['coreCount'] ?? 0,
      perCoreUsage: (json['perCoreUsage'] as List<dynamic>?)?.map((e) => (e as num).toDouble()).toList() ?? [],
    );
  }
}

class GpuTelemetry {
  final String name;
  final double? usagePercent;
  final double? temperatureCelsius;
  final double vramTotalMb;
  final double? vramUsedMb;
  final double? fanSpeedPercent;

  GpuTelemetry({
    required this.name,
    this.usagePercent,
    this.temperatureCelsius,
    required this.vramTotalMb,
    this.vramUsedMb,
    this.fanSpeedPercent,
  });

  factory GpuTelemetry.fromJson(Map<String, dynamic> json) {
    return GpuTelemetry(
      name: json['name'] ?? 'Unknown GPU',
      usagePercent: json['usagePercent']?.toDouble(),
      temperatureCelsius: json['temperatureCelsius']?.toDouble(),
      vramTotalMb: (json['vramTotalMb'] ?? 0).toDouble(),
      vramUsedMb: json['vramUsedMb']?.toDouble(),
      fanSpeedPercent: json['fanSpeedPercent']?.toDouble(),
    );
  }
}

class RamTelemetry {
  final double totalGb;
  final double usedGb;
  final double freeGb;
  final double usagePercent;

  RamTelemetry({
    required this.totalGb,
    required this.usedGb,
    required this.freeGb,
    required this.usagePercent,
  });

  factory RamTelemetry.fromJson(Map<String, dynamic> json) {
    return RamTelemetry(
      totalGb: (json['totalGb'] ?? 0).toDouble(),
      usedGb: (json['usedGb'] ?? 0).toDouble(),
      freeGb: (json['freeGb'] ?? 0).toDouble(),
      usagePercent: (json['usagePercent'] ?? 0).toDouble(),
    );
  }
}

class FanTelemetry {
  final String mode;
  final bool? max;
  final List<FanInfo> fans;

  FanTelemetry({
    required this.mode,
    this.max,
    required this.fans,
  });

  factory FanTelemetry.fromJson(Map<String, dynamic> json) {
    return FanTelemetry(
      mode: json['mode'] ?? 'unknown',
      max: json['max'] as bool?,
      fans: (json['fans'] as List<dynamic>?)?.map((e) => FanInfo.fromJson(e)).toList() ?? [],
    );
  }
}

class FanInfo {
  final int id;
  final int speedRpm;
  final double? speedPercent;

  FanInfo({
    required this.id,
    required this.speedRpm,
    this.speedPercent,
  });

  factory FanInfo.fromJson(Map<String, dynamic> json) {
    return FanInfo(
      id: json['id'] ?? 0,
      speedRpm: json['speedRpm'] ?? 0,
      speedPercent: json['speedPercent']?.toDouble(),
    );
  }
}