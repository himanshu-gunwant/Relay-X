import * as chokidar from 'chokidar';
import fs from 'fs/promises';
import path from 'path';
import EventEmitter from 'events';
import { Service, RelayEvents } from './types';
import { AntigravityContext } from '../bootstrap/types';
import { RawTranscriptStep, TranscriptEvent, EventCategory } from '../models/event';

export class TranscriptWatcherService extends EventEmitter implements Service {
  private watcher!: chokidar.FSWatcher;
  private cursors = new Map<string, number>();
  private titleCache = new Map<string, string>();
  private brainDir!: string;
  private workspaceDir!: string;
  private pruneInterval?: NodeJS.Timeout;

  // We type the native emit
  public emit<K extends keyof RelayEvents>(event: K, ...args: Parameters<RelayEvents[K]>): boolean {
    return super.emit(event, ...args);
  }
  public on<K extends keyof RelayEvents>(event: K, listener: RelayEvents[K]): this {
    return super.on(event, listener);
  }

  async start(ctx: AntigravityContext): Promise<void> {
    this.brainDir = ctx.brainDir;
    this.workspaceDir = ctx.workspaceDir;

    // Chokidar v4 removed native glob support. Watch brainDir recursively
    // and filter to only transcript_full.jsonl files in event handlers.
    this.watcher = chokidar.watch(this.brainDir, {
      persistent: true,
      ignoreInitial: false,
      awaitWriteFinish: {
        stabilityThreshold: 200,
        pollInterval: 100
      },
      usePolling: false
    });

    this.watcher.on('add', (filePath: string) => {
      if (path.basename(filePath) !== 'transcript_full.jsonl') return;
      this.onFileAdded(filePath);
    });
    this.watcher.on('change', (filePath: string) => {
      if (path.basename(filePath) !== 'transcript_full.jsonl') return;
      this.onFileChanged(filePath);
    });

    this.pruneInterval = setInterval(() => this.pruneStale(), 3600000); // Every hour
  }

  async stop(): Promise<void> {
    if (this.pruneInterval) clearInterval(this.pruneInterval);
    if (this.watcher) {
      await this.watcher.close();
    }
  }

  onContextRefresh(ctx: AntigravityContext): void {
    this.workspaceDir = ctx.workspaceDir;
    if (this.brainDir !== ctx.brainDir) {
      this.stop().then(() => this.start(ctx));
    }
  }

  async getHistory(conversationId: string, options?: { limit?: number; beforeIndex?: number }): Promise<TranscriptEvent[]> {
    const filePath = path.join(this.brainDir, conversationId, '.system_generated', 'logs', 'transcript_full.jsonl');
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const lines = content.split('\n').filter(l => l.trim().length > 0);
      const events: TranscriptEvent[] = [];
      for (const line of lines) {
        try {
          const step = JSON.parse(line) as RawTranscriptStep;
          if (options?.beforeIndex !== undefined && step.step_index >= options.beforeIndex) {
            continue;
          }
          events.push(this.classifyStep(conversationId, step));
        } catch (e) {
          // Ignore parse errors for history
        }
      }
      if (options?.limit) {
        return events.slice(-options.limit);
      }
      return events;
    } catch (err: any) {
      if (err.code === 'ENOENT') {
        return [];
      }
      throw err;
    }
  }

  async listConversations(): Promise<{ id: string; title: string; updatedAt: string; project: string; workspace: string }[]> {
    const results: { id: string; title: string; updatedAt: string; timeMs: number; project: string; workspace: string }[] = [];
    try {
      const entries = await fs.readdir(this.brainDir, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isDirectory()) continue;
        const conversationId = entry.name;
        // Basic UUID check
        if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(conversationId)) continue;
        
        let transcriptPath = path.join(this.brainDir, conversationId, '.system_generated', 'logs', 'transcript_full.jsonl');
        try {
          let stats;
          try {
            stats = await fs.stat(transcriptPath);
          } catch (e) {
            transcriptPath = path.join(this.brainDir, conversationId, '.system_generated', 'logs', 'transcript.jsonl');
            stats = await fs.stat(transcriptPath);
          }
          let title = this.titleCache.get(conversationId);
          
          if (!title) {
            const content = await fs.readFile(transcriptPath, 'utf-8');
            const lines = content.split('\n').filter(l => l.trim().length > 0);
            title = 'New Conversation';
            for (const line of lines) {
              try {
                const step = JSON.parse(line) as RawTranscriptStep;
                if (step.type === 'USER_INPUT' && step.content) {
                  const match = step.content.match(/<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/);
                  let cleanContent = match ? match[1] : step.content;
                  cleanContent = cleanContent.replace(/<[^>]+>/g, '').replace(/\s+/g, ' ').trim();
                  title = cleanContent;
                  if (title.length > 50) title = title.substring(0, 50) + '...';
                  break;
                }
              } catch (e) {}
            }
            this.titleCache.set(conversationId, title);
          }
          let project = 'General';
          let workspace = this.workspaceDir;
          try {
            // 1. Try parsing the project name from the Cwd or DirectoryPath of the first few tool calls
            const content = await fs.readFile(transcriptPath, 'utf-8');
            const lines = content.split('\n').filter(l => l.trim().length > 0);
            
            for (const line of lines.slice(0, 100)) {
              try {
                const step = JSON.parse(line);
                if (step.tool_calls) {
                  let foundPath: string | null = null;
                  for (const tc of step.tool_calls) {
                    if (tc.args && tc.args.Cwd) {
                      foundPath = tc.args.Cwd;
                      break;
                    }
                    if (tc.args && tc.args.DirectoryPath) {
                      foundPath = tc.args.DirectoryPath;
                      break;
                    }
                  }
                  if (foundPath) {
                    foundPath = foundPath.replace(/^"|"$/g, '').trim();
                    const normalized = foundPath.replace(/\\/g, '/');
                    project = this.getProjectFromPath(normalized);
                    workspace = normalized;
                    break;
                  }
                }
              } catch (e) {}
            }

            // 2. Fallback to querying the SQLite db if still 'General'
            if (project === 'General') {
              try {
                const dbPath = path.join(this.brainDir, '..', 'conversations', `${conversationId}.db`);
                const { exec } = await import('child_process');
                const { promisify } = await import('util');
                const execAsync = promisify(exec);
                const { stdout } = await execAsync(`sqlite3 "${dbPath}" "PRAGMA busy_timeout = 3000; SELECT cast(data as text) FROM trajectory_metadata_blob WHERE id = 'main';"`);
                const match = stdout.match(/file:\/\/\/[a-zA-Z0-9%\-._~:\/ ]+/);
                if (match) {
                  const uri = match[0];
                  const decoded = decodeURIComponent(uri);
                  workspace = decoded.replace(/^file:\/\/\//, '');
                  project = this.getProjectFromPath(workspace);
                }
              } catch (err) {
                // CLI query failed or sqlite3 not installed
              }
            }

            // Clean up any trailing binary control characters or replacement characters (e.g. \uFFFD)
            project = project.replace(/[\x00-\x1F\x7F-\x9F\uFFFD]/g, '').trim();
            workspace = path.resolve(workspace.replace(/[\x00-\x1F\x7F-\x9F\uFFFD]/g, '').trim()).replace(/\\/g, '/');

            // If the workspace URI was a file with a query param (e.g. index.ts?x), group under Subagents
            if (project.includes('?')) {
              project = 'Subagents';
            }
          } catch (e) {
            // Fallback to General if parsing fails
          }

          results.push({
            id: conversationId,
            title,
            updatedAt: stats.mtime.toISOString(),
            timeMs: stats.mtimeMs,
            project,
            workspace
          });
        } catch (err) {
          // Ignore if no transcript
        }
      }
    } catch (err: any) {
      if (err.code !== 'ENOENT') throw err;
    }

    results.sort((a, b) => b.timeMs - a.timeMs);
    return results.map(r => ({ id: r.id, title: r.title, updatedAt: r.updatedAt, project: r.project, workspace: r.workspace }));
  }

  // Keep track of the last processed state to detect updates
  private lastState = new Map<string, { lineCount: number; lastLineLength: number }>();

  private async onFileAdded(filePath: string) {
    const conversationId = this.extractConversationId(filePath);
    
    // Automatically self-heal both log files if they contain trailing corrupted lines from crashes
    const dir = path.dirname(filePath);
    const transcriptPath = path.join(dir, 'transcript.jsonl');
    await this.selfHealLogFile(filePath);
    await this.selfHealLogFile(transcriptPath);

    // Initialize state to the end of the file to prevent flooding historical messages on startup
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const lines = content.split('\n').filter(line => line.trim().length > 0);
      this.lastState.set(conversationId, { 
        lineCount: lines.length, 
        lastLineLength: lines.length > 0 ? lines[lines.length - 1].length : 0 
      });
    } catch (e) {
      this.lastState.set(conversationId, { lineCount: 0, lastLineLength: 0 });
    }
  }

  private async selfHealLogFile(filePath: string) {
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const lines = content.split('\n');
      let lastValidIdx = -1;
      let hasCorruption = false;
      
      for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i].trim();
        if (!line) continue;
        try {
          JSON.parse(line);
          lastValidIdx = i;
          break;
        } catch (e) {
          hasCorruption = true;
        }
      }
      
      if (hasCorruption && lastValidIdx !== -1) {
        console.warn(`[TranscriptWatcher] Auto-healing: Trailing corruption detected in ${path.basename(filePath)}. Truncating.`);
        const cleanContent = lines.slice(0, lastValidIdx + 1).join('\n') + '\n';
        await fs.writeFile(filePath, cleanContent, 'utf-8');
      }
    } catch (err: any) {
      if (err.code !== 'ENOENT') {
        console.error(`[TranscriptWatcher] Self-healing failed for ${filePath}:`, err.message);
      }
    }
  }

  private async onFileChanged(filePath: string) {
    const conversationId = this.extractConversationId(filePath);
    await this.readNewLines(conversationId, filePath);
  }

  private extractConversationId(filePath: string): string {
    const parts = filePath.split(path.sep);
    const brainIdx = parts.lastIndexOf('brain');
    if (brainIdx !== -1 && parts.length > brainIdx + 1) {
      return parts[brainIdx + 1];
    }
    return path.basename(path.dirname(path.dirname(path.dirname(filePath))));
  }

  private async pruneStale() {
    for (const [conversationId] of this.lastState) {
      const p = path.join(this.brainDir, conversationId);
      try {
        await fs.stat(p);
      } catch (err) {
        this.lastState.delete(conversationId);
      }
    }
  }

  private async readNewLines(conversationId: string, filePath: string) {
    try {
      const content = await fs.readFile(filePath, 'utf-8');
      const lines = content.split('\n').filter(line => line.trim().length > 0);
      
      const state = this.lastState.get(conversationId) ?? { lineCount: 0, lastLineLength: 0 };
      
      // If the file was truncated/cleared, reset state
      if (lines.length < state.lineCount) {
        state.lineCount = 0;
        state.lastLineLength = 0;
      }
      
      for (let i = Math.max(0, state.lineCount - 1); i < lines.length; i++) {
        const line = lines[i];
        
        // Skip if this is the exact same last line we already processed
        if (i === state.lineCount - 1 && line.length === state.lastLineLength) {
          continue;
        }

        try {
          const step = JSON.parse(line) as RawTranscriptStep;
          const event = this.classifyStep(conversationId, step);
          this.emit('transcript:step', conversationId, event);
        } catch (err) {
          // It's possible the daemon is mid-write and the JSON is malformed.
          // We don't advance the state for this line, so we'll retry it on the next change.
          continue;
        }
        
        // Update state to reflect successfully processed line
        if (i >= state.lineCount) {
          state.lineCount = i + 1;
        }
        if (i === lines.length - 1) {
          state.lastLineLength = line.length;
        }
      }
      
      this.lastState.set(conversationId, state);
    } catch (err: any) {
      if (err.code !== 'ENOENT') {
        console.error(`[TranscriptWatcher] Error reading ${filePath}:`, err);
      }
    }
  }

  private classifyStep(conversationId: string, raw: RawTranscriptStep): TranscriptEvent {
    const base = {
      conversationId,
      stepIndex:   raw.step_index,
      source:      this.normalizeSource(raw.source),
      status:      (raw.status?.toLowerCase() || 'pending') as 'done' | 'error' | 'pending',
      timestamp:   raw.created_at,
      hasThinking: !!raw.thinking,
      error:       raw.error,
    };

    let category: EventCategory;
    let summary: string;

    switch (raw.type) {
      case 'USER_INPUT':
        if (raw.content?.includes('<USER_SETTINGS_CHANGE>') && !raw.content?.includes('<USER_REQUEST>')) {
          category = 'system_info';
          summary = 'Model selection updated';
        } else {
          category = 'user_message';
          summary = this.truncate(this.extractUserPrompt(raw.content || ''), 120);
        }
        break;

      case 'SYSTEM_MESSAGE': {
        // Messages sent via `agentapi send-message` arrive as SYSTEM_MESSAGE
        // with the user's content wrapped in <SYSTEM_MESSAGE> tags.
        // Treat these as user messages so the mobile UI shows them correctly.
        category = 'user_message';
        summary = this.truncate(this.extractRelayedUserMessage(raw.content || ''), 120);
        break;
      }

      case 'PLANNER_RESPONSE':
        if (raw.tool_calls?.length) {
          category = 'tool_invocation';
          summary = raw.tool_calls
            .map(tc => tc.args?.toolSummary || tc.name)
            .join(', ');
        } else {
          category = 'agent_response';
          summary = this.truncate(raw.content || '', 120);
        }
        break;

      case 'RUN_COMMAND':
      case 'LIST_DIRECTORY':
      case 'VIEW_FILE':
      case 'GREP_SEARCH':
      case 'WRITE_FILE':
      case 'REPLACE_FILE_CONTENT':
      case 'READ_URL_CONTENT':
      case 'INVOKE_SUBAGENT':
      case 'CALL_MCP_TOOL':
      case 'GENERIC':
        category = 'tool_result';
        summary = raw.type === 'GENERIC' ? `Tool Result: ${this.truncate(raw.content || '', 80)}` : `${raw.type}: ${this.truncate(raw.content || '', 80)}`;
        break;

      case 'ERROR_MESSAGE':
        category = 'error';
        summary = raw.error || raw.content || 'Unknown error';
        break;

      default:
        category = 'system_info';
        summary = raw.type;
    }

    // For SYSTEM_MESSAGE steps relayed from the mobile app, extract the
    // clean user content and override the source to 'user'.
    let effectiveSource = base.source;
    let effectiveContent = raw.content ? raw.content.substring(0, 10240) : undefined;
    
    if (raw.type === 'USER_INPUT') {
      // The Antigravity backend natively injects <USER_REQUEST> and <ADDITIONAL_METADATA>
      // into all USER_INPUT steps. We strip this out so the mobile UI stays clean.
      effectiveContent = this.extractUserPrompt(raw.content || '');
    } else if (raw.type === 'SYSTEM_MESSAGE' && category === 'user_message') {
      effectiveSource = 'user';
      effectiveContent = this.extractRelayedUserMessage(raw.content || '');
    }

    const toolCalls = raw.tool_calls?.map(tc => ({
      name:    tc.name,
      summary: (tc.args?.toolSummary as string) || tc.name,
      action:  (tc.args?.toolAction as string) || '',
    }));

    return { ...base, source: effectiveSource, category, summary, content: effectiveContent, toolCalls };
  }

  private normalizeSource(source: string): 'user' | 'model' | 'system' {
    if (source === 'USER_EXPLICIT') return 'user';
    if (source === 'MODEL') return 'model';
    return 'system';
  }

  private extractUserPrompt(content: string): string {
    const match = content.match(/<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/);
    let result = match ? match[1] : content;
    result = result.replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/g, '');
    result = result.replace(/<USER_SETTINGS_CHANGE>[\s\S]*?<\/USER_SETTINGS_CHANGE>/g, '');
    return result.trim();
  }

  private extractRelayedUserMessage(content: string): string {
    const tagMatch = content.match(/<SYSTEM_MESSAGE>\s*([\s\S]*?)\s*<\/SYSTEM_MESSAGE>/);
    if (tagMatch) return tagMatch[1].trim();
    return content;
  }

  private truncate(str: string, len: number): string {
    if (str.length <= len) return str;
    return str.substring(0, len) + '...';
  }

  private getProjectFromPath(filePath: string): string {
    const normalized = filePath.replace(/\\/g, '/');
    const parts = normalized.split('/').filter(p => p.length > 0);
    if (parts.length === 0) return 'General';
    
    if (parts[0].toLowerCase().startsWith('d:')) {
      return parts[1] || parts[0];
    }
    
    if (parts[0].toLowerCase().startsWith('c:') && parts[1]?.toLowerCase() === 'users' && parts[2]) {
      if (parts[3] === '.gemini' && parts[4] === 'antigravity') {
        return 'Antigravity';
      }
      if (['desktop', 'documents', 'source', 'repos'].includes(parts[3]?.toLowerCase())) {
        return parts[4] || parts[3];
      }
      return parts[3] || 'General';
    }
    
    return parts[parts.length - 1] || 'General';
  }
}
