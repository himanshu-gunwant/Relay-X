import { EventEmitter } from 'events';
import { Service } from './types.js';
import { AntigravityContext } from '../bootstrap/types.js';
import si from 'systeminformation';
import { exec, execSync } from 'child_process';
import { promisify } from 'util';
import path from 'path';
import fs from 'fs';
import { config } from '../config.js';
import { HardwareTelemetry, FanMode, PerformanceMode } from '../models/hardware.js';

const execAsync = promisify(exec);

// OmenMon support removed.

function getActivePowerScheme(): FanMode {
  try {
    const stdout = execSync('powercfg /getactivescheme').toString();
    if (stdout.includes('8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')) {
      return 'performance';
    } else if (stdout.includes('a1841308-3541-4fab-bc81-f71556f20b4a')) {
      return 'cool'; // Maps to Eco/Quiet in mobile UI
    } else {
      return 'default'; // Maps to Balanced in mobile UI
    }
  } catch (e) {
    return 'unknown';
  }
}

export class HardwareMonitorService extends EventEmitter implements Service {
  private ctx!: AntigravityContext;
  private intervalId: NodeJS.Timeout | null = null;
  private currentTelemetry: HardwareTelemetry | null = null;
  private isFanMaxActive: boolean = false;

  async start(ctx: AntigravityContext): Promise<void> {
    this.ctx = ctx;
    // Initial fetch
    try {
      this.currentTelemetry = await this.fetchTelemetry();
      this.emit('hardware:telemetry', this.currentTelemetry);
    } catch (err) {
      console.error('[HardwareMonitor] Initial fetch failed:', err);
    }
    this.startPolling();
    console.log('[HardwareMonitor] Service started.');
  }

  async stop(): Promise<void> {
    if (this.intervalId) {
      clearInterval(this.intervalId);
      this.intervalId = null;
    }
    console.log('[HardwareMonitor] Service stopped.');
  }

  onContextRefresh(ctx: AntigravityContext): void {
    this.ctx = ctx;
  }

  getTelemetry(): HardwareTelemetry | null {
    return this.currentTelemetry;
  }

  private startPolling() {
    // Poll every 3 seconds
    this.intervalId = setInterval(async () => {
      try {
        const telemetry = await this.fetchTelemetry();
        this.currentTelemetry = telemetry;
        this.emit('hardware:telemetry', telemetry);
      } catch (err) {
        console.error('[HardwareMonitor] Failed to fetch telemetry:', err);
      }
    }, 3000);
  }

  private async fetchTelemetry(): Promise<HardwareTelemetry> {
    const [cpuLoad, memInfo] = await Promise.all([
      si.currentLoad(),
      si.mem()
    ]);

    const activeScheme = getActivePowerScheme();

    return {
      cpu: {
        usagePercent: cpuLoad.currentLoad,
        temperatureCelsius: null,
        coreCount: cpuLoad.cpus.length,
        perCoreUsage: cpuLoad.cpus.map(c => c.load)
      },
      gpu: {
        name: 'GPU Monitoring Disabled',
        usagePercent: null,
        temperatureCelsius: null,
        vramTotalMb: 0,
        vramUsedMb: null,
        fanSpeedPercent: null
      },
      ram: {
        totalGb: memInfo.total / (1024 ** 3),
        usedGb: memInfo.used / (1024 ** 3),
        freeGb: memInfo.free / (1024 ** 3),
        usagePercent: (memInfo.used / memInfo.total) * 100
      },
      fans: {
        mode: activeScheme,
        max: this.isFanMaxActive,
        fans: []
      },
      timestamp: Date.now()
    };
  }

  async setFanMode(mode: string): Promise<boolean> {
    try {
      let guid = '381b4222-f694-41f0-9685-ff5bb260df2e'; // Balanced
      if (mode.toLowerCase() === 'performance') {
        guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c';
      } else if (mode.toLowerCase() === 'eco' || mode.toLowerCase() === 'quiet' || mode.toLowerCase() === 'cool') {
        guid = 'a1841308-3541-4fab-bc81-f71556f20b4a';
      }

      execSync(`powercfg /setactive ${guid}`);
      console.log(`[HardwareMonitor] Active Windows Power Plan set to: ${mode} (${guid})`);
      return true;
    } catch (e) {
      console.error('[HardwareMonitor] Failed to set Windows power scheme:', e);
      return false;
    }
  }

  async setFanLevel(level1: number, level2: number): Promise<boolean> {
    // Legacy support, do nothing
    return true;
  }

  async setFanMax(max: boolean): Promise<boolean> {
    // OmenMon removed, stubbing for UI compatibility
    this.isFanMaxActive = max;
    console.log(`[HardwareMonitor] FanMax stub set to: ${max}`);
    return true;
  }
}
