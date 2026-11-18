import { execFile } from 'child_process';
import { promisify } from 'util';
import { Mutex } from 'async-mutex';
import { Service } from './types';
import { AntigravityContext } from '../bootstrap/types';
import * as crypto from 'crypto';
import * as https from 'https';
import path from 'path';

const execFileAsync = promisify(execFile);

export interface AgentapiError {
  code: 'CONNECTION_FAILED' | 'CSRF_INVALID' | 'PROJECT_MISSING'
      | 'UNKNOWN_COMMAND' | 'TIMEOUT' | 'PROCESS_EXITED' | 'UNKNOWN';
  message: string;
  retryable: boolean;
}

export interface AgentapiResult<T> {
  success: boolean;
  data?: T;
  error?: AgentapiError;
}

export interface NewConversationResponse {
  conversationId: string;
}

export interface ConversationMetadata {
  workspaces: Array<{
    workspaceFolderAbsoluteUri: string;
    gitRootAbsoluteUri: string;
    branchName: string;
    repository: {
      computedName: string;
      gitOriginUrl: string;
    };
  }>;
  createdAt: string;          
  projectId: string;
  nestingDepth: number;
  parentConversationId: string;
  rootConversationId: string;
  tags: string[];
}

export interface SendMessageResponse {
  
}

interface AgentapiAdapter {
  buildNewConversationArgs(prompt: string, model?: string): string[];
  buildSendMessageArgs(recipientId: string, content: string): string[];
  buildGetMetadataArgs(conversationId: string): string[];
  parseResponse(stdout: string): { response: any; error?: string };
}

class AgentapiV2Adapter implements AgentapiAdapter {
  buildNewConversationArgs(prompt: string, model?: string): string[] {
    const args = ['new-conversation'];
    if (model) args.push(`--model=${model}`);
    args.push(prompt);
    return args;
  }

  buildSendMessageArgs(recipientId: string, content: string): string[] {
    const wrappedContent = `[MOBILE_MESSAGE_START]\n${content}\n[MOBILE_MESSAGE_END]\n\n(Agent Instruction: The text between the tags above is a direct message from the human user using the Relay-X remote app. Please respond to them directly as their AI assistant.)`;
    return ['send-message', recipientId, wrappedContent];
  }

  buildGetMetadataArgs(conversationId: string): string[] {
    return ['get-conversation-metadata', conversationId];
  }

  parseResponse(stdout: string) {
    // Raw shape: { response: { <commandName>: { ...fields } }, error?: "..." }
    const raw = JSON.parse(stdout.trim());
    if (raw.error) {
      return { response: null, error: raw.error };
    }
    // Unwrap the nested command object into a flat response
    const inner = raw.response || {};
    // Pick the first (and only) key inside response, e.g. "newConversation"
    const commandKey = Object.keys(inner)[0];
    const flattened = commandKey ? inner[commandKey] : {};
    return { response: flattened, error: undefined };
  }
}

export class AgentapiService implements Service {
  private ctx!: AntigravityContext;
  private execLock = new Mutex();
  private adapter: AgentapiAdapter = new AgentapiV2Adapter();
  
  public recentlyCreatedProjects = new Map<string, { id: string, name: string, workspace: string }>();
  private readonly MODEL_MAP: Record<string, string> = {
    // Current Antigravity models (Late 2026 / 1.3.1)
    'gemini_3.8_flash_high': 'gemini-3.8-flash-high',
    'gemini_3.8_flash_medium': 'gemini-3.8-flash-medium',
    'gemini_3.8_flash_low': 'gemini-3.8-flash-low',
    'claude_sonnet_4.6_thinking': 'claude-sonnet-4-6',
    'claude_opus_4.6_thinking': 'claude-opus-4-6-thinking',
    'gpt_oss_120b_medium': 'gpt-oss-120b-medium',
    // Direct slug pass-throughs
    'gemini-3.8-flash-high': 'gemini-3.8-flash-high',
    'gemini-3.8-flash-medium': 'gemini-3.8-flash-medium',
    'gemini-3.8-flash-low': 'gemini-3.8-flash-low',
    'claude-sonnet-4-6': 'claude-sonnet-4-6',
    'claude-opus-4-6-thinking': 'claude-opus-4-6-thinking',
    'gpt-oss-120b-medium': 'gpt-oss-120b-medium',
    // Backwards compatibility with previous mobile app versions
    'gemini_3.5_flash_high_fast': 'gemini-3.8-flash-high',
    'gemini_3.5_flash_medium': 'gemini-3.8-flash-medium',
    'gemini_3.5_flash_low': 'gemini-3.8-flash-low',
    'gemini_3.1_pro_low': 'gemini-3.8-flash-medium',
    'gemini_3.1_pro_high': 'gemini-3.8-flash-high',
  };

  private resolveModel(modelKey?: string): string {
    if (!modelKey) return 'gemini-3.8-flash-high';
    return this.MODEL_MAP[modelKey] || modelKey;
  }

  async start(ctx: AntigravityContext): Promise<void> {
    this.ctx = ctx;
  }

  async stop(): Promise<void> {
    // Nothing to clean up
  }

  onContextRefresh(ctx: AntigravityContext): void {
    this.ctx = ctx;
  }

  updateActiveProject(newProjectId: string): void {
    if (this.ctx) {
      this.ctx.projectId = newProjectId;
      console.log(`[Agentapi] Switched active project context to: ${newProjectId}`);
    }
  }

  async createProject(projectId: string, name: string, targetDirectory: string): Promise<boolean> {
    const payloadObj = {
      project: {
        id: projectId,
        name: name,
        projectResources: {
          resources: [{ folderUri: `file:///${targetDirectory.replace(/\\/g, '/').replace(/:/g, '%3A')}` }]
        },
        settings: {
          fileAccessPolicy: "AGENT_SETTING_POLICY_ALLOW",
          internetPolicy: "AGENT_SETTING_POLICY_ASK",
          autoExecutionPolicy: "CASCADE_COMMANDS_AUTO_EXECUTION_EAGER",
          artifactReviewMode: "ARTIFACT_REVIEW_MODE_ALWAYS"
        }
      }
    };
    
    const payloadString = JSON.stringify(payloadObj);
    const payloadBuffer = Buffer.from(payloadString, 'utf8');
    const frameHeader = Buffer.alloc(5);
    frameHeader.writeUInt8(0, 0);
    frameHeader.writeUInt32BE(payloadBuffer.length, 1);
    const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);
    
    const trySend = async (portIdx: number): Promise<boolean> => {
      if (portIdx >= this.ctx.lsPorts.length) return false;
      const port = this.ctx.lsPorts[portIdx];
      
      const options = {
        hostname: '127.0.0.1',
        port: port,
        path: '/exa.language_server_pb.LanguageServerService/CreateProject',
        method: 'POST',
        rejectUnauthorized: false,
        timeout: 10000,
        headers: {
          'x-codeium-csrf-token': this.ctx.csrfToken,
          'content-type': 'application/grpc-web+json',
          'x-grpc-web': '1',
          'content-length': grpcWebBody.length,
          'User-Agent': 'Relay-X-App'
        }
      };

      console.log(`[Agentapi] CreateProject payload:`, payloadString);

      return new Promise((res) => {
        const req = https.request(options, (response: any) => {
          let chunks: any[] = [];
          response.on('data', (chunk: any) => chunks.push(chunk));
          response.on('end', () => {
            const body = Buffer.concat(chunks).toString('utf8');
            console.log(`[Agentapi] CreateProject response: Port=${port}, Status=${response.statusCode}, Headers=${JSON.stringify(response.headers)}, Body=${body}`);
            const grpcStatus = response.headers['grpc-status'] || (response.trailers && response.trailers['grpc-status']);
            if (response.statusCode >= 200 && response.statusCode < 300 && (!grpcStatus || grpcStatus === '0')) {
              res(true);
            } else {
              console.error(`[Agentapi] CreateProject failed with grpc-status: ${grpcStatus}`);
              if (grpcStatus && grpcStatus !== '0') {
                res(false); // Stop retrying if we hit the actual gRPC server but got an application error
              } else {
                res(trySend(portIdx + 1));
              }
            }
          });
        });
        req.on('error', (err: any) => {
          console.error(`[Agentapi] CreateProject req error on port ${port}:`, err.message);
          res(trySend(portIdx + 1));
        });
        req.on('timeout', () => {
          console.error(`[Agentapi] CreateProject timeout on port ${port}`);
          req.destroy();
          res(trySend(portIdx + 1));
        });
        req.write(grpcWebBody);
        req.end();
      });
    };

    const success = await trySend(0);
    if (success) {
      this.recentlyCreatedProjects.set(targetDirectory, {
        id: projectId,
        name: name,
        workspace: targetDirectory
      });
      this.updateActiveProject(projectId);
    }
    return success;
  }

  private formatPromptWithModelChange(content: string, modelChange: { from: string; to: string }): string {
    const tzoffset = (new Date()).getTimezoneOffset() * 60000;
    const localISOTime = (new Date(Date.now() - tzoffset)).toISOString().slice(0, -1);
    
    const offsetMin = (new Date()).getTimezoneOffset();
    const offsetSign = offsetMin <= 0 ? '+' : '-';
    const offsetHours = Math.floor(Math.abs(offsetMin) / 60).toString().padStart(2, '0');
    const offsetMins = (Math.abs(offsetMin) % 60).toString().padStart(2, '0');
    const offsetStr = `${offsetSign}${offsetHours}:${offsetMins}`;

    const timestamp = `${localISOTime}${offsetStr}`;

    return `<USER_REQUEST>\n${content}\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe current local time is: ${timestamp}.\n</ADDITIONAL_METADATA>\n<USER_SETTINGS_CHANGE>\nThe user changed setting \`Model Selection\` from ${modelChange.from} to ${modelChange.to}. No need to comment on this change if the user doesn't ask about it. If reporting what model you are, please use a human readable name instead of the exact string.\n</USER_SETTINGS_CHANGE>`;
  }

  async newConversation(
    prompt: string,
    model?: 'flash_lite' | 'flash' | 'pro',
    modelChange?: { from: string; to: string },
    selectedModel?: string,
    projectId?: string
  ): Promise<AgentapiResult<NewConversationResponse>> {
    const conversationId = crypto.randomUUID();
    const gRpcModel = this.resolveModel(selectedModel);

    await this.writeModelState(gRpcModel);

    const targetProjectId = projectId || this.ctx.projectId;
    console.log(`[Agentapi] newConversation using projectId: ${targetProjectId}, model: ${gRpcModel}`);

    // Native StartCascade
    const startPayloadObj = {
      source: 'CORTEX_TRAJECTORY_SOURCE_CASCADE_CLIENT',
      cascadeId: conversationId,
      requestedModel: gRpcModel,
      projectEnvConfig: {
        projectId: targetProjectId,
        defaultProjectEnvironment: {}
      }
    };
    
    const payloadString = JSON.stringify(startPayloadObj);
    const payloadBuffer = Buffer.from(payloadString, 'utf8');

    const frameHeader = Buffer.alloc(5);
    frameHeader.writeUInt8(0, 0);
    frameHeader.writeUInt32BE(payloadBuffer.length, 1);

    const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);

    const trySend = async (portIdx: number): Promise<boolean> => {
      if (portIdx >= this.ctx.lsPorts.length) return false;
      const port = this.ctx.lsPorts[portIdx];
      
      const options = {
        hostname: '127.0.0.1',
        port: port,
        path: '/exa.language_server_pb.LanguageServerService/StartCascade',
        method: 'POST',
        rejectUnauthorized: false,
        timeout: 10000,
        headers: {
          'x-codeium-csrf-token': this.ctx.csrfToken,
          'content-type': 'application/grpc-web+json',
          'x-grpc-web': '1',
          'content-length': grpcWebBody.length,
          'User-Agent': 'Relay-X-App'
        }
      };

      console.log(`[Agentapi] StartCascade payload:`, payloadString);

      return new Promise((res) => {
        const req = https.request(options, (response: any) => {
          let chunks: any[] = [];
          response.on('data', (chunk: any) => chunks.push(chunk));
          response.on('end', () => {
            const body = Buffer.concat(chunks).toString('utf8');
            console.log(`[Agentapi] StartCascade response: Port=${port}, Status=${response.statusCode}, Headers=${JSON.stringify(response.headers)}, Body=${body}`);
            const grpcStatus = response.headers['grpc-status'] || (response.trailers && response.trailers['grpc-status']);
            if (response.statusCode >= 200 && response.statusCode < 300 && (!grpcStatus || grpcStatus === '0')) {
              res(true);
            } else {
              console.error(`[Agentapi] StartCascade failed with grpc-status: ${grpcStatus}`);
              if (grpcStatus && grpcStatus !== '0') {
                res(false);
              } else {
                res(trySend(portIdx + 1));
              }
            }
          });
        });
        req.on('error', (err: any) => {
          console.error(`[Agentapi] StartCascade req error on port ${port}:`, err.message);
          res(trySend(portIdx + 1));
        });
        req.on('timeout', () => {
          console.error(`[Agentapi] StartCascade timeout on port ${port}`);
          req.destroy();
          res(trySend(portIdx + 1));
        });
        req.write(grpcWebBody);
        req.end();
      });
    };

    const startSuccess = await trySend(0);
    if (!startSuccess) {
      return { success: false, error: { code: 'UNKNOWN', message: 'Failed to StartCascade', retryable: false } };
    }

    // Now send the initial message natively
    const sendResult = await this.sendMessage(conversationId, prompt, modelChange, selectedModel);
    if (!sendResult.success) {
      return { success: false, error: sendResult.error };
    }

    return {
      success: true,
      data: {
        conversationId
      }
    };
  }

  async sendMessage(
    recipientId: string,
    content: string,
    modelChange?: { from: string; to: string },
    model?: string
  ): Promise<AgentapiResult<SendMessageResponse>> {
    const finalPrompt = content;
    const gRpcModel = this.resolveModel(model);
    
    console.log(`[Agentapi] sendMessage called with model: ${model}, resolved to gRpcModel: ${gRpcModel}`);

    // We bypass the 'agentapi' CLI here because the CLI sends a SYSTEM_MESSAGE.
    // Instead, we use the raw gRPC-Web endpoint to natively inject a USER message.
    
    // Set the active model state in the language server first!
    await this.writeModelState(gRpcModel);

      const payloadObj = {
        cascadeId: recipientId,
        items: [{ text: finalPrompt }],
        cascadeConfig: {
          plannerConfig: {
            conversational: { plannerMode: 'CONVERSATIONAL_PLANNER_MODE_DEFAULT', agenticMode: true },
            toolConfig: {
              runCommand: { autoCommandConfig: { autoExecutionPolicy: 'CASCADE_COMMANDS_AUTO_EXECUTION_PROCEED_IN_SANDBOX' }, enableTerminalSandbox: false },
              antigravityBrowser: { browserJsExecutionPolicy: 'BROWSER_JS_EXECUTION_POLICY_ALWAYS_ASK' },
              notifyUser: { artifactReviewMode: 'ARTIFACT_REVIEW_MODE_ALWAYS' },
              permissionConfig: {
                enterpriseConfig: { enforceWorkspaceValidation: false },
                effectiveGrants: { allow: [] },
                defaultGrants: { allow: ['command(*)'], ask: ['read_url(*)'] }
              }
            },
            requestedModel: { model: gRpcModel },
            knowledgeConfig: {},
            useAiCredits: true,
            supportsLatexRendering: true
          }
        },
        conversationHistoryConfig: {}
      };

      const payloadString = JSON.stringify(payloadObj);
      console.log(`[Agentapi] sending payload:`, payloadString);
      const payloadBuffer = Buffer.from(payloadString, 'utf8');

      const frameHeader = Buffer.alloc(5);
      frameHeader.writeUInt8(0, 0);
      frameHeader.writeUInt32BE(payloadBuffer.length, 1);

      const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);
      
      const trySend = async (portIdx: number, attempt = 1): Promise<AgentapiResult<SendMessageResponse>> => {
        if (portIdx >= this.ctx.lsPorts.length) {
          if (attempt < 3) {
            console.warn(`[Agentapi] sendMessage failed on all ports. Retrying (attempt ${attempt + 1}/3)...`);
            await new Promise(r => setTimeout(r, 1000 * attempt));
            return trySend(0, attempt + 1);
          }
          return { success: false, error: { code: 'CONNECTION_FAILED', message: 'All gRPC ports failed', retryable: true } };
        }
        
        const port = this.ctx.lsPorts[portIdx];
        const options = {
          hostname: '127.0.0.1',
          port: port,
          path: '/exa.language_server_pb.LanguageServerService/SendUserCascadeMessage',
          method: 'POST',
          rejectUnauthorized: false,
          timeout: 10000,
          headers: {
            'x-codeium-csrf-token': this.ctx.csrfToken,
            'content-type': 'application/grpc-web+json',
            'x-grpc-web': '1',
            'content-length': grpcWebBody.length,
            'User-Agent': 'Relay-X-App'
          }
        };

        return new Promise((res) => {
          const req = https.request(options, (response: any) => {
            let responseData = '';
            response.on('data', (chunk: any) => { responseData += chunk; });
            response.on('end', () => {
              const grpcStatus = response.headers['grpc-status'] || (response.trailers && response.trailers['grpc-status']);
              if (response.statusCode >= 200 && response.statusCode < 300 && (!grpcStatus || grpcStatus === '0')) {
                res({ success: true, data: {} });
              } else {
                console.error(`[Agentapi] SendUserCascadeMessage failed with grpc-status: ${grpcStatus}`);
                if (grpcStatus && grpcStatus !== '0') {
                  res({ success: false, error: { code: 'UNKNOWN', message: `Server returned grpc-status: ${grpcStatus}`, retryable: false } });
                } else {
                  res(trySend(portIdx + 1, attempt));
                }
              }
            });
          });

          req.on('error', (e: any) => {
            res(trySend(portIdx + 1, attempt));
          });
          req.on('timeout', () => { req.destroy(); res(trySend(portIdx + 1, attempt)); });

          req.write(grpcWebBody);
          req.end();
        });
      };

      return trySend(0);
  }

  private async writeModelState(gRpcModel: string): Promise<void> {
    const payloadObj = {
      appState: {
        lastSelectedAgentModel: gRpcModel
      }
    };
    const payloadString = JSON.stringify(payloadObj);
    const payloadBuffer = Buffer.from(payloadString, 'utf8');

    const frameHeader = Buffer.alloc(5);
    frameHeader.writeUInt8(0, 0);
    frameHeader.writeUInt32BE(payloadBuffer.length, 1);

    const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);

    const trySend = async (portIdx: number): Promise<boolean> => {
      if (portIdx >= this.ctx.lsPorts.length) {
        return false;
      }
      
      const port = this.ctx.lsPorts[portIdx];
      const options = {
        hostname: '127.0.0.1',
        port: port,
        path: '/exa.language_server_pb.LanguageServerService/JetboxWriteState',
        method: 'POST',
        rejectUnauthorized: false,
        timeout: 10000,
        headers: {
          'x-codeium-csrf-token': this.ctx.csrfToken,
          'content-type': 'application/grpc-web+json',
          'x-grpc-web': '1',
          'content-length': grpcWebBody.length,
          'User-Agent': 'Relay-X-App'
        }
      };

      return new Promise((res) => {
        const req = https.request(options, (response: any) => {
          response.on('data', () => {});
          response.on('end', () => {
            if (response.statusCode >= 200 && response.statusCode < 300) {
              res(true);
            } else {
              res(trySend(portIdx + 1));
            }
          });
        });

        req.on('error', () => {
          res(trySend(portIdx + 1));
        });
        req.on('timeout', () => { req.destroy(); res(trySend(portIdx + 1)); });

        req.write(grpcWebBody);
        req.end();
      });
    };

    await trySend(0);
  }

  async getConversationMetadata(
    conversationId: string
  ): Promise<AgentapiResult<ConversationMetadata>> {
    const args = this.adapter.buildGetMetadataArgs(conversationId);
    return this.exec<ConversationMetadata>(args);
  }

  async getQuotaSummary(): Promise<AgentapiResult<any>> {

    const payloadBuffer = Buffer.from('{}', 'utf8');
    const frameHeader = Buffer.alloc(5);
    frameHeader.writeUInt8(0, 0);
    frameHeader.writeUInt32BE(payloadBuffer.length, 1);
    const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);

    const trySend = (portIdx: number): Promise<AgentapiResult<any>> => {
      if (portIdx >= this.ctx.lsPorts.length) {
        return Promise.resolve({ success: false, error: { code: 'CONNECTION_FAILED', message: 'Failed to reach Language Server', retryable: true } });
      }

      const port = this.ctx.lsPorts[portIdx];
      const options = {
        hostname: '127.0.0.1',
        port: port,
        path: '/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary',
        method: 'POST',
        rejectUnauthorized: false,
        timeout: 10000,
        headers: {
          'x-codeium-csrf-token': this.ctx.csrfToken,
          'content-type': 'application/grpc-web+json',
          'x-grpc-web': '1',
          'content-length': grpcWebBody.length,
          'User-Agent': 'Relay-X-App'
        }
      };

      return new Promise((res) => {
        const req = https.request(options, (response: any) => {
          let data = '';
          response.on('data', (d: any) => data += d.toString());
          response.on('end', () => {
            if (response.statusCode >= 200 && response.statusCode < 300) {
              try {
                const jsonStr = data.substring(data.indexOf('{'), data.lastIndexOf('}') + 1);
                res({ success: true, data: JSON.parse(jsonStr) });
              } catch(e: any) {
                res({ success: false, error: { code: 'UNKNOWN', message: 'Failed to parse JSON', retryable: false } });
              }
            } else {
              res(trySend(portIdx + 1));
            }
          });
        });

        req.on('error', () => {
          res(trySend(portIdx + 1));
        });
        req.on('timeout', () => { req.destroy(); res(trySend(portIdx + 1)); });

        req.write(grpcWebBody);
        req.end();
      });
    };

    return trySend(0);
  }

  async cancelConversation(conversationId: string): Promise<AgentapiResult<any>> {
    if (!this.ctx || !this.ctx.lsPorts || this.ctx.lsPorts.length === 0) {
      return { success: false, error: { code: 'CONNECTION_FAILED', message: 'No Language Server ports available', retryable: false } };
    }

    const payloadObj = { cascadeId: conversationId };
    const payloadString = JSON.stringify(payloadObj);
    const payloadBuffer = Buffer.from(payloadString, 'utf8');

    const frameHeader = Buffer.alloc(5);
    frameHeader.writeUInt8(0, 0);
    frameHeader.writeUInt32BE(payloadBuffer.length, 1);
    const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);

    const endpoints = [
      '/exa.language_server_pb.LanguageServerService/CancelCascadeInvocation',
      '/exa.language_server_pb.LanguageServerService/ForceStopCascadeTree',
    ];

    const trySend = (endpointIdx: number, portIdx: number): Promise<AgentapiResult<any>> => {
      if (endpointIdx >= endpoints.length) {
        return Promise.resolve({ success: false, error: { code: 'UNKNOWN', message: 'Failed to cancel cascade across all endpoints and ports', retryable: false } });
      }
      if (portIdx >= this.ctx.lsPorts.length) {
        return trySend(endpointIdx + 1, 0);
      }

      const port = this.ctx.lsPorts[portIdx];
      const endpoint = endpoints[endpointIdx];

      const options = {
        hostname: '127.0.0.1',
        port: port,
        path: endpoint,
        method: 'POST',
        rejectUnauthorized: false,
        timeout: 5000,
        headers: {
          'x-codeium-csrf-token': this.ctx.csrfToken,
          'content-type': 'application/grpc-web+json',
          'x-grpc-web': '1',
          'content-length': grpcWebBody.length,
          'User-Agent': 'Relay-X-App'
        }
      };

      return new Promise((res) => {
        const req = https.request(options, (response: any) => {
          let data = '';
          response.on('data', (d: any) => data += d.toString());
          response.on('end', () => {
            if (response.statusCode >= 200 && response.statusCode < 300) {
              console.log(`[Agentapi] Successfully cancelled cascade ${conversationId} via ${endpoint} on port ${port}`);
              res({ success: true, data: { status: 'cancelled', endpoint } });
            } else {
              res(trySend(endpointIdx, portIdx + 1));
            }
          });
        });

        req.on('error', () => {
          res(trySend(endpointIdx, portIdx + 1));
        });
        req.on('timeout', () => {
          req.destroy();
          res(trySend(endpointIdx, portIdx + 1));
        });

        req.write(grpcWebBody);
        req.end();
      });
    };

    return trySend(0, 0);
  }

  private async exec<T>(args: string[]): Promise<AgentapiResult<T>> {
    return this.execLock.runExclusive(async () => {
      let attempt = 0;
      const maxRetries = 3;
      
      while (true) {
        attempt++;
        const env = {
          ...process.env,
          ANTIGRAVITY_LS_ADDRESS:  `localhost:${Math.max(...this.ctx.lsPorts)}`,
          ANTIGRAVITY_CSRF_TOKEN:  this.ctx.csrfToken,
          ANTIGRAVITY_PROJECT_ID:  this.ctx.projectId,
        };

        try {
          let stdout = '';
          let stderr = '';
          
          const fs = require('fs/promises');
          const batContent = await fs.readFile(this.ctx.agentapiBat, 'utf-8');
          const exeMatch = batContent.match(/"([^"]+)"\s+agentapi/);
          
          if (exeMatch && exeMatch[1]) {
            const lsExe = exeMatch[1];
            const result = await execFileAsync(
              lsExe,
              ['agentapi', ...args],
              { env, timeout: 30_000, windowsHide: true }
            );
            stdout = result.stdout;
            stderr = result.stderr;
          } else {
            const result = await execFileAsync(
              'cmd.exe',
              ['/c', this.ctx.agentapiBat, ...args],
              { env, timeout: 30_000, windowsHide: true }
            );
            stdout = result.stdout;
            stderr = result.stderr;
          }

          console.log(`[Agentapi] stdout for [${args[0]}]:`, stdout.trim());
          if (stderr) console.warn(`[Agentapi] stderr:`, stderr.trim());

          const parsed = this.adapter.parseResponse(stdout);

          if (parsed.error) {
            const error = this.classifyError(parsed.error);
            if (error.code === 'CONNECTION_FAILED' && attempt <= maxRetries) {
              console.warn(`[Agentapi] exec connection failed. Retrying (${attempt}/${maxRetries})...`);
              await new Promise(r => setTimeout(r, 1000 * attempt));
              continue;
            }
            if (error.code === 'UNKNOWN_COMMAND') {
              console.error(`[CRITICAL] Agentapi threw UNKNOWN_COMMAND for ${args[0]}. The Antigravity Relay Server must be updated to match the latest API schema.`);
            }
            return { success: false, error };
          }

          return { success: true, data: parsed.response as T };
        } catch (err: any) {
          console.error(`[Agentapi] exec error for [${args[0]}]:`, err.message);
          const error = this.classifyError(err.message);
          
          if (error.code === 'CONNECTION_FAILED' && attempt <= maxRetries) {
            console.warn(`[Agentapi] exec connection failed. Retrying (${attempt}/${maxRetries})...`);
            await new Promise(r => setTimeout(r, 1000 * attempt));
            continue;
          }
          
          if (err.killed) {
            return { success: false, error: { code: 'TIMEOUT', message: 'Command timed out after 30s', retryable: true } };
          }
          
          return { success: false, error };
        }
      }
    });
  }

  private classifyError(message: string): AgentapiError {
    if (message.includes('missing CSRF token'))
      return { code: 'CSRF_INVALID', message, retryable: false };

    if (message.includes('project_id is required'))
      return { code: 'PROJECT_MISSING', message, retryable: false };

    if (message.includes('connection refused') || message.includes('ECONNREFUSED'))
      return { code: 'CONNECTION_FAILED', message, retryable: true };

    if (message.includes('unknown command'))
      return { code: 'UNKNOWN_COMMAND', message, retryable: false };

    return { code: 'UNKNOWN', message, retryable: true };
  }
}
