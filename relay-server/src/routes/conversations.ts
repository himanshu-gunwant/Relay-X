import { FastifyInstance } from 'fastify';
import { AgentapiService } from '../services/agentapi.js';
import { OverviewService } from '../services/overview.js';
import path from 'path';
import fs from 'fs';
import crypto from 'crypto';
import os from 'os';

export async function conversationsRoutes(
  fastify: FastifyInstance,
  options: { agentapi: AgentapiService, transcripts: any, ctx: any }
) {
  const { agentapi, transcripts, ctx } = options;
  const overviewService = ctx ? new OverviewService(ctx.brainDir) : null;

  fastify.get('/:id/overview', async (request, reply) => {
    if (!overviewService) return reply.status(500).send({ error: 'Context not found' });
    const { id } = request.params as { id: string };
    try {
      const overview = await overviewService.getConversationOverview(id);
      return overview;
    } catch (err: any) {
      return reply.status(500).send({ error: err.message });
    }
  });

  fastify.get('/:id/artifacts/:filename', async (request, reply) => {
    const { id, filename } = request.params as { id: string, filename: string };
    if (!ctx) return reply.status(500).send({ error: 'Context not found' });
    
    try {
      // Security: Prevent path traversal
      const safeName = path.basename(filename);
      const safeId = path.basename(id);
      const artifactDir = path.join(ctx.brainDir, safeId);
      const filePath = path.join(artifactDir, safeName);
      
      if (!filePath.startsWith(artifactDir)) {
        return reply.status(403).send({ error: 'Path traversal blocked' });
      }

      const ext = path.extname(filePath).toLowerCase();
      
      let contentType = 'application/octet-stream';
      if (ext === '.md') contentType = 'text/markdown';
      else if (ext === '.png') contentType = 'image/png';
      else if (ext === '.jpg' || ext === '.jpeg') contentType = 'image/jpeg';
      
      const stream = fs.createReadStream(filePath);
      stream.on('error', (err: NodeJS.ErrnoException) => {
        if (err.code === 'ENOENT') {
          reply.status(404).send({ error: 'Artifact not found' });
        } else {
          reply.status(500).send({ error: 'Error reading artifact' });
        }
      });
      return reply.type(contentType).send(stream);
    } catch (err: any) {
      return reply.status(500).send({ error: 'Internal Server Error' });
    }
  });

  fastify.get('/:id/artifacts', async (request, reply) => {
    const { id } = request.params as { id: string };
    if (!ctx) return reply.status(500).send({ error: 'Context not found' });
    
    try {
      const safeId = path.basename(id);
      const artifactDir = path.join(ctx.brainDir, safeId);
      
      let entries: { filename: string, isMedia: boolean, modifiedAt: string, absolutePath: string }[] = [];
      try {
        const files = await fs.promises.readdir(artifactDir, { withFileTypes: true });
        for (const file of files) {
          if (file.isFile() && !file.name.endsWith('.jsonl') && !file.name.startsWith('.')) {
            // Check if it's an image
            const isMedia = ['.png', '.jpg', '.jpeg', '.gif', '.webp', '.mp4'].some(ext => file.name.toLowerCase().endsWith(ext));
            
            // We ignore JSON metadata files as they are just backing metadata for MD files
            if (file.name.endsWith('.json') && !file.name.endsWith('.jsonl')) continue;

            const stats = await fs.promises.stat(path.join(artifactDir, file.name));
            const absolutePath = path.join(artifactDir, file.name).replace(/\\/g, '/');
            entries.push({
              filename: file.name,
              isMedia,
              modifiedAt: stats.mtime.toISOString(),
              absolutePath,
            });
          }
        }
      } catch (err: any) {
        if (err.code !== 'ENOENT') throw err;
      }
      
      // Sort newest first
      entries.sort((a, b) => new Date(b.modifiedAt).getTime() - new Date(a.modifiedAt).getTime());
      
      return reply.send({ artifacts: entries });
    } catch (err: any) {
      return reply.status(500).send({ error: 'Failed to list artifacts', details: err.message });
    }
  });

  fastify.get('/:id/history', async (request, reply) => {
    const { id } = request.params as { id: string };
    const { limit, beforeIndex } = request.query as { limit?: string, beforeIndex?: string };
    
    try {
      const parsedLimit = limit ? parseInt(limit, 10) : undefined;
      const parsedBeforeIndex = beforeIndex ? parseInt(beforeIndex, 10) : undefined;
      
      const history = await transcripts.getHistory(id, { limit: parsedLimit, beforeIndex: parsedBeforeIndex });
      return reply.send({ history });
    } catch (err: any) {
      return reply.status(500).send({ error: 'Failed to fetch history', details: err.message });
    }
  });

  fastify.get('/', async (request, reply) => {
    try {
      const conversations = await transcripts.listConversations();
      return reply.send({ conversations });
    } catch (err: any) {
      return reply.status(500).send({ error: 'Failed to list conversations', details: err.message });
    }
  });

  fastify.post('/', async (request, reply) => {
    const { prompt, model, modelChange, selectedModel, workspace } = request.body as { 
      prompt: string; 
      model?: 'flash_lite' | 'flash' | 'pro'; 
      modelChange?: { from: string; to: string };
      selectedModel?: string;
      workspace?: string;
    };
    if (!prompt) {
      request.log.error({ body: request.body, headers: request.headers }, 'Missing prompt in request');
      return reply.status(400).send({ error: 'prompt is required', receivedBody: request.body });
    }

    let targetProjectId: string | undefined;

    if (workspace) {
      try {
        const convs = await transcripts.listConversations();
        const existing = convs.find((c: any) => {
          const cPath = c.workspace ? c.workspace.replace(/\\/g, '/').toLowerCase() : '';
          const wPath = workspace.replace(/\\/g, '/').toLowerCase();
          return cPath === wPath;
        });

        if (existing) {
          console.log(`[Relay] Found existing conversation ${existing.id} for workspace ${workspace}. Fetching projectId...`);
          const metaResult = await agentapi.getConversationMetadata(existing.id);
          if (metaResult.success && metaResult.data) {
            targetProjectId = metaResult.data.projectId;
            console.log(`[Relay] Resolved workspace ${workspace} to existing projectId: ${targetProjectId}`);
          }
        }

        if (!targetProjectId) {
          // Fallback to reading agyhub_summaries_proto.pb and app_storage.json
          const hubFile = path.join(os.homedir(), '.gemini', 'antigravity', 'agyhub_summaries_proto.pb');
          const appStoreFile = path.join(os.homedir(), 'AppData', 'Roaming', 'Antigravity', 'app_storage.json');
          
          if (fs.existsSync(hubFile)) {
            const hubData = fs.readFileSync(hubFile, 'utf8');
            let activeIds = new Set<string>();
            
            if (fs.existsSync(appStoreFile)) {
              try {
                const appStore = JSON.parse(fs.readFileSync(appStoreFile, 'utf8'));
                // Extract all valid UUIDs from the keys or values in app_storage.json
                const uuidRegex = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;
                for (const key of Object.keys(appStore)) {
                  const kmatch = key.match(uuidRegex);
                  if (kmatch) activeIds.add(kmatch[1]);
                  const vmatch = String(appStore[key]).match(uuidRegex);
                  if (vmatch) activeIds.add(vmatch[1]);
                }
              } catch(e) {}
            }

            const wPath = workspace.replace(/\\/g, '/').replace(/ /g, '%20');
            const escapedPath = wPath.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&');
            const regex = new RegExp(`file:\\/\\/\\/${escapedPath}.*?\\$([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})`, 'ig');
            
            let match;
            const candidates = [];
            while ((match = regex.exec(hubData)) !== null) {
              candidates.push(match[1]);
            }
            
            if (candidates.length > 0) {
              // Prefer candidates that are still marked active in the Desktop App's state.
              // Search backwards to pick the MOST RECENT active project ID.
              const activeCandidate = [...candidates].reverse().find(id => activeIds.has(id));
              targetProjectId = activeCandidate || candidates[candidates.length - 1]; // fallback to most recent if none are "active"
              console.log(`[Relay] Resolved workspace ${workspace} from agyhub to existing projectId: ${targetProjectId}`);
            }
          }
        }

        if (!targetProjectId) {
          const newProjectId = crypto.randomUUID();
          const name = path.basename(workspace) || 'Remote Project';
          console.log(`[Relay] No existing project found for ${workspace}. Registering new projectId: ${newProjectId}`);
          const success = await agentapi.createProject(newProjectId, name, workspace);
          if (success) {
            targetProjectId = newProjectId;
          }
        }
      } catch (err: any) {
        console.error('[Relay] Error resolving projectId for workspace:', err.message);
      }
    }

    let result = await agentapi.newConversation(prompt, model, modelChange, selectedModel, targetProjectId);
    
    // If StartCascade failed, the resolved targetProjectId might be stale or deleted from the daemon.
    if (!result.success && result.error?.message === 'Failed to StartCascade' && workspace) {
      console.log(`[Relay] StartCascade failed for resolved projectId ${targetProjectId}. It may be stale. Registering a new one...`);
      const newProjectId = crypto.randomUUID();
      const name = path.basename(workspace) || 'Remote Project';
      const success = await agentapi.createProject(newProjectId, name, workspace);
      if (success) {
        targetProjectId = newProjectId;
        console.log(`[Relay] Retrying newConversation with fresh projectId: ${targetProjectId}`);
        result = await agentapi.newConversation(prompt, model, modelChange, selectedModel, targetProjectId);
      }
    }

    if (!result.success || !result.data) {
      return reply.status(500).send({ error: result.error?.message || 'Failed to create conversation' });
    }

    return reply.status(201).send({
      id: result.data.conversationId,
      createdAt: new Date().toISOString(),
    });
  });

  fastify.get('/:id', async (request, reply) => {
    const { id } = request.params as { id: string };
    const result = await agentapi.getConversationMetadata(id);
    if (!result.success || !result.data) {
      return reply.status(404).send({ error: result.error?.message || 'Conversation not found' });
    }

    return reply.status(200).send(result.data);
  });

  fastify.get('/:id/messages', async (request, reply) => {
    const { id } = request.params as { id: string };
    try {
      const history = await transcripts.getHistory(id);
      return reply.send({ messages: history });
    } catch (err: any) {
      return reply.status(500).send({ error: 'Failed to retrieve history', details: err.message });
    }
  });

  fastify.post('/:id/messages', async (request, reply) => {
    const { id } = request.params as { id: string };
    const { content, modelChange, model } = request.body as { content: string; modelChange?: { from: string; to: string }; model?: string };
    if (!content) {
      return reply.status(400).send({ error: 'content is required' });
    }
    console.log(`[Relay] sendMessage called for ${id} with model: ${model}`);

    const result = await agentapi.sendMessage(id, content, modelChange, model);
    if (!result.success) {
      return reply.status(500).send({ error: result.error?.message || 'Failed to send message' });
    }

    return reply.status(200).send({});
  });

  fastify.post('/:id/cancel', async (request, reply) => {
    const { id } = request.params as { id: string };
    console.log(`[Relay] Cancel requested for conversation: ${id}`);
    const result = await agentapi.cancelConversation(id);
    if (!result.success) {
      return reply.status(500).send({ error: result.error?.message || 'Failed to cancel conversation' });
    }
    return reply.status(200).send({ success: true, message: 'Turn cancelled successfully' });
  });

  fastify.post('/projects/new', async (request, reply) => {
    console.log('[Relay] HIT POST /projects/new endpoint!');
    const { targetDirectory } = request.body as { targetDirectory: string };
    if (!targetDirectory) {
      return reply.status(400).send({ error: 'targetDirectory is required' });
    }
    
    try {
      const crypto = await import('crypto');
      const newProjectId = crypto.randomUUID();
      const name = path.basename(targetDirectory) || 'Remote Project';
      
      let success = await agentapi.createProject(newProjectId, name, targetDirectory);
      
      if (!success) {
        const uniqueName = `${name}-${newProjectId.split('-')[0]}`;
        console.log(`[Relay] Retrying CreateProject with unique name: ${uniqueName}`);
        success = await agentapi.createProject(newProjectId, uniqueName, targetDirectory);
      }
      
      if (success) {
        return reply.send({ success: true, message: 'Project initialized remotely!', projectId: newProjectId });
      } else {
        return reply.status(500).send({ error: 'Failed to create project via Language Server.' });
      }
    } catch (err: any) {
      return reply.status(500).send({ error: 'Failed to launch project', details: err.message });
    }
  });
}
