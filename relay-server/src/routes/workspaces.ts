import { FastifyInstance } from 'fastify';
import fs from 'fs';
import os from 'os';
import path from 'path';

function extractProjectName(workspacePath: string): string {
  const parts = workspacePath.replace(/\\/g, '/').split('/').filter(p => p.length > 0);
  if (parts.length === 0) return 'General';
  
  if (parts[0].toLowerCase().startsWith('d:')) {
    return parts[1] || parts[0];
  }
  
  if (parts[0].toLowerCase().startsWith('c:') && parts[1]?.toLowerCase() === 'users') {
    // Basic heuristic to get meaningful project name
    const docIdx = parts.findIndex(p => ['desktop', 'documents', 'source', 'repos'].includes(p.toLowerCase()));
    if (docIdx !== -1 && parts.length > docIdx + 1) {
      return parts[docIdx + 1];
    }
    return parts[parts.length - 1] || 'General';
  }
  
  return parts[parts.length - 1] || 'General';
}
import { AgentapiService } from '../services/agentapi.js';

export async function workspacesRoutes(
  fastify: FastifyInstance,
  options: { agentapi?: AgentapiService }
) {
  fastify.get('/', async (request, reply) => {
    try {
      const hubFile = path.join(os.homedir(), '.gemini', 'antigravity', 'agyhub_summaries_proto.pb');
      const appStoreFile = path.join(os.homedir(), 'AppData', 'Roaming', 'Antigravity', 'app_storage.json');
      
      const workspacesMap = new Map<string, { id: string, name: string, workspace: string }>();

      if (fs.existsSync(hubFile) && fs.existsSync(appStoreFile)) {
        const hubData = fs.readFileSync(hubFile, 'utf8');
        let activeIds = new Set<string>();
        
        try {
          const appStore = JSON.parse(fs.readFileSync(appStoreFile, 'utf8'));
          const uuidRegex = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i;
          for (const key of Object.keys(appStore)) {
            const kmatch = key.match(uuidRegex);
            if (kmatch) activeIds.add(kmatch[1]);
            const vmatch = String(appStore[key]).match(uuidRegex);
            if (vmatch) activeIds.add(vmatch[1]);
          }
        } catch(e) {}

        // Match patterns like: file:///d:/EduTrack or file:///d%3A/EduTrack followed by UUID
        const fileRegex = /file:\/\/\/([a-zA-Z0-9%\-._~:/\\ ]+).*?\$([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/ig;
        let match;
        
        // We will store all discovered paths keyed by UUID temporarily
        const candidates = new Map<string, string>();
        while ((match = fileRegex.exec(hubData)) !== null) {
          let workspaceUri = match[1];
          // Decode any URL encoding
          workspaceUri = decodeURIComponent(workspaceUri);

          // Since we're parsing a binary protobuf using regex, trailing garbage bytes
          // might be interpreted as valid ASCII. We can trim them by checking the filesystem.
          if (workspaceUri.length > 2 && workspaceUri[1] === ':') {
             let cleanPath = workspaceUri;
             while (cleanPath.length > 3 && !fs.existsSync(cleanPath)) {
                 cleanPath = cleanPath.substring(0, cleanPath.length - 1);
             }
             if (cleanPath.length >= 3 && fs.existsSync(cleanPath)) {
                 workspaceUri = cleanPath;
             }
          }

          candidates.set(match[2], workspaceUri);
        }

        // Filter to only active ones
        for (const [id, workspacePath] of candidates.entries()) {
          if (activeIds.has(id)) {
            const projectName = extractProjectName(workspacePath);
            // Ensure no duplicates by using workspacePath as key
            workspacesMap.set(workspacePath, { id, name: projectName, workspace: workspacePath });
          }
        }
      }

      // Add recently created projects from memory that might not be on disk yet
      if (options.agentapi) {
        for (const [workspace, proj] of options.agentapi.recentlyCreatedProjects.entries()) {
          if (!workspacesMap.has(workspace)) {
            workspacesMap.set(workspace, proj);
          }
        }
      }

      const results = Array.from(workspacesMap.values());
      results.sort((a, b) => a.name.localeCompare(b.name));
      
      return { workspaces: results };
    } catch (err: any) {
      fastify.log.error(err);
      return reply.code(500).send({ error: 'Failed to list workspaces', details: err.message });
    }
  });
}
