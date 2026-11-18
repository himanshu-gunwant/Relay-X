export interface HardwareTelemetry {
  cpu: CpuTelemetry;
  gpu: GpuTelemetry;
  ram: RamTelemetry;
  fans: FanTelemetry;
  macAddress?: string | null;
  timestamp: number;
}

export interface CpuTelemetry {
  usagePercent: number;
  temperatureCelsius: number | null;
  coreCount: number;
  perCoreUsage: number[];
}

export interface GpuTelemetry {
  name: string;
  usagePercent: number | null;
  temperatureCelsius: number | null;
  vramTotalMb: number;
  vramUsedMb: number | null;
  fanSpeedPercent: number | null;
}

export interface RamTelemetry {
  totalGb: number;
  usedGb: number;
  freeGb: number;
  usagePercent: number;
}

export interface FanTelemetry {
  mode: FanMode;
  max: boolean | null;
  fans: FanInfo[];
}

export interface FanInfo {
  id: number;
  speedRpm: number;
  speedPercent: number | null;
}

export type FanMode = 'default' | 'performance' | 'cool' | 'manual' | 'unknown';
export type PerformanceMode = 'default' | 'performance' | 'cool' | 'unknown';
