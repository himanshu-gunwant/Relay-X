import { FastifyInstance } from 'fastify';
import * as https from 'https';
import crypto from 'crypto';
import path from 'path';
import { AntigravityContext } from '../bootstrap/types.js';

interface WorkspacesGrpcRouteOptions {
  ctx: AntigravityContext;
}

export async function workspacesGrpcRoutes(fastify: FastifyInstance, options: WorkspacesGrpcRouteOptions) {
  const { ctx } = options;

  fastify.get('/', async (request, reply) => {
    try {
      if (!ctx || ctx.lsPorts.length === 0) {
        return reply.code(503).send({ error: 'Language server not connected' });
      }

      const port = ctx.lsPorts[0];
      const csrf = ctx.csrfToken;
      
      const payloadBuffer = Buffer.from(JSON.stringify({ uris: ['file:///d:/TESTTEST'] }), 'utf8');
      const frameHeader = Buffer.alloc(5);
      frameHeader.writeUInt8(0, 0);
      frameHeader.writeUInt32BE(payloadBuffer.length, 1);
      const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);

      const reqOptions = {
        hostname: '127.0.0.1',
        port: port,
        path: '/exa.language_server_pb.LanguageServerService/GetWorkspaceInfos',
        method: 'POST',
        rejectUnauthorized: false,
        timeout: 5000,
        headers: {
          'x-codeium-csrf-token': csrf,
          'content-type': 'application/grpc-web+json',
          'x-grpc-web': '1',
          'content-length': grpcWebBody.length,
          'User-Agent': 'Antigravity-Companion-App'
        }
      };

      const rawResponse = await new Promise<string>((resolve, reject) => {
        const req = https.request(reqOptions, (res) => {
          let chunks: Buffer[] = [];
          res.on('data', d => chunks.push(d));
          res.on('end', () => {
            const buffer = Buffer.concat(chunks);
            // Skip the 5-byte header
            if (buffer.length > 5) {
              const body = buffer.subarray(5).toString('utf8');
              // The response from grpc-web+json includes trailer bytes at the end like "grpc-status: 0"
              // We want to slice everything up to the last closing brace of the JSON payload.
              const jsonEnd = body.lastIndexOf('}');
              if (jsonEnd !== -1) {
                resolve(body.substring(0, jsonEnd + 1));
              } else {
                resolve(body);
              }
            } else {
              resolve('');
            }
          });
        });
        
        req.on('error', reject);
        req.on('timeout', () => {
          req.destroy();
          reject(new Error('Timeout connecting to language server'));
        });
        
        req.write(grpcWebBody);
        req.end();
      });

      fastify.log.info(`[workspaces-grpc] Raw JSON response length: ${rawResponse.length}`);

      if (!rawResponse) {
        return { workspaces: [] };
      }

      const parsed = JSON.parse(rawResponse);
      const workspaceInfos = parsed.workspaceInfos || [];
      const results = [];

      for (const info of workspaceInfos) {
        // Phase 3 Adapter Mapping: map WorkspaceInfo back into the old schema.
        const workspaceUri = info.workspaceUri || '';
        const baseFolder = info.baseFolder || '';
        const corpusName = info.corpusName || '';
        
        if (!workspaceUri) continue;
        
        // Use baseFolder as the workspace path if available, else attempt to clean up URI
        let workspacePath = baseFolder;
        if (!workspacePath && workspaceUri.startsWith('file:///')) {
          workspacePath = decodeURIComponent(workspaceUri.substring(8));
        }

        // Generate synthetic id deterministically from URI
        const id = crypto.createHash('sha256').update(workspaceUri).digest('hex').substring(0, 36);
        
        // Re-implement the extraction heuristic from old API to retain format compatibility
        let projectName = corpusName;
        if (!projectName) {
          const parts = workspacePath.replace(/\\/g, '/').split('/').filter((p: string) => p.length > 0);
          if (parts.length > 0) {
            if (parts[0].toLowerCase().startsWith('c:') && parts[1]?.toLowerCase() === 'users') {
              const docIdx = parts.findIndex((p: string) => ['desktop', 'documents', 'source', 'repos'].includes(p.toLowerCase()));
              if (docIdx !== -1 && parts.length > docIdx + 1) {
                projectName = parts[docIdx + 1];
              }
            }
            if (!projectName) {
               projectName = parts[parts.length - 1] || 'General';
            }
          } else {
            projectName = 'General';
          }
        }

        results.push({
          id,
          name: projectName,
          workspace: workspacePath,
          rawInfo: info // Included purely for debugging/evidence in Phase 2
        });
      }

      // Add General as fallback if empty, matching old endpoint behavior
      if (results.length === 0) {
        results.push({
          id: '00000000-0000-0000-0000-000000000000',
          name: 'General',
          workspace: 'General',
          rawInfo: null
        });
      }

      results.sort((a, b) => a.name.localeCompare(b.name));

      return { workspaces: results, rawResponse: parsed };
    } catch (err: any) {
      fastify.log.error(`[workspaces-grpc] Error: ${err.message}`);
      return reply.code(500).send({ error: 'Failed to list workspaces via gRPC', details: err.message });
    }
  });
}
