import * as path from 'path';
import * as fs from 'fs/promises';
import { createHash } from 'crypto';
import { Service } from './types';
import { AntigravityContext } from '../bootstrap/types';
import fg from 'fast-glob';

export interface BuildArtifact {
  id: string;
  name: string;
  type: 'apk' | 'aab' | 'web' | 'exe' | 'other';
  fileName: string;
  absolutePath: string;
  sizeBytes: number;
  detectedAt: string;
  modifiedAt: string;
}

interface BuildPattern {
  name: string;
  glob: string;
  type: BuildArtifact['type'];
}

const DEFAULT_PATTERNS: BuildPattern[] = [
  {
    name: 'Flutter APK',
    glob: '**/build/app/outputs/flutter-apk/**/*.apk',
    type: 'apk',
  },
  {
    name: 'Android APK',
    glob: '**/build/app/outputs/apk/**/*.apk',
    type: 'apk',
  },
  {
    name: 'Android AAB',
    glob: '**/build/app/outputs/bundle/**/*.aab',
    type: 'aab',
  },
  {
    name: 'Release APK',
    glob: '**/{release,dist}/**/*.apk',
    type: 'apk',
  },
  {
    name: 'Web Build',
    glob: '**/{dist,build/web,out}/**/index.html',
    type: 'web',
  },
  {
    name: 'Dist/Release Artifacts',
    glob: '**/{release,dist}/**/*.{exe,zip,dmg}',
    type: 'other',
  },
  {
    name: 'Screenshots',
    glob: '**/screenshots/**/*.png',
    type: 'other',
  },
];

export class BuildDetectorService implements Service {
  private knownBuilds = new Map<string, BuildArtifact>();
  
  async start(ctx: AntigravityContext): Promise<void> {
    // No-op. Watchers are removed in favor of stateless on-demand scans.
  }

  async stop(): Promise<void> {
    // No-op
  }

  onContextRefresh(ctx: AntigravityContext): void {
    // No-op
  }

  /**
   * Performs an on-demand filesystem scan for build artifacts in a specified workspace.
   */
  async scanWorkspace(workspacePath: string): Promise<BuildArtifact[]> {
    try {
      // Validate workspace path existence
      const workspaceStat = await fs.stat(workspacePath);
      if (!workspaceStat.isDirectory()) {
        throw new Error('Workspace path is not a directory');
      }

      const foundArtifacts: BuildArtifact[] = [];

      for (const pattern of DEFAULT_PATTERNS) {
        const matches = await fg(pattern.glob, {
          cwd: workspacePath,
          absolute: true,
          onlyFiles: true,
          ignore: ['**/node_modules/**', '**/.git/**', '**/.dart_tool/**'],
          deep: 8,
        });

        for (const filePath of matches) {
          try {
            const stat = await fs.stat(filePath);
            const id = createHash('md5').update(filePath).digest('hex');

            const artifact: BuildArtifact = {
              id,
              name: pattern.name,
              type: pattern.type,
              fileName: path.basename(filePath),
              absolutePath: filePath,
              sizeBytes: stat.size,
              detectedAt: new Date().toISOString(),
              modifiedAt: stat.mtime.toISOString(),
            };
            
            foundArtifacts.push(artifact);
            this.knownBuilds.set(id, artifact);
          } catch (fileErr) {
            console.warn(`[BuildDetector] Failed to stat file ${filePath}:`, fileErr);
          }
        }
      }

      // Sort by modification time, newest first
      foundArtifacts.sort((a, b) => new Date(b.modifiedAt).getTime() - new Date(a.modifiedAt).getTime());

      // Limit returned artifacts
      return foundArtifacts.slice(0, 50);

    } catch (error: any) {
      console.error(`[BuildDetector] Failed to scan workspace ${workspacePath}:`, error);
      return [];
    }
  }

  listBuilds(): BuildArtifact[] {
    return Array.from(this.knownBuilds.values()).reverse();
  }
  
  getBuild(id: string): BuildArtifact | undefined {
    return this.knownBuilds.get(id);
  }
}
