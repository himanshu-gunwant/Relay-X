import { FastifyInstance } from 'fastify';
import * as https from 'https';
import { AntigravityContext } from '../bootstrap/types.js';

interface CustomizationsRouteOptions {
  ctx: AntigravityContext;
}

export async function customizationsRoutes(fastify: FastifyInstance, options: CustomizationsRouteOptions) {
  const { ctx } = options;

  async function callLanguageServer(endpoint: string, payload: any = {}): Promise<any> {
    if (!ctx || ctx.lsPorts.length === 0) {
      throw new Error('Language server not connected');
    }

    const payloadBuffer = Buffer.from(JSON.stringify(payload), 'utf8');
    const frameHeader = Buffer.alloc(5);
    frameHeader.writeUInt8(0, 0);
    frameHeader.writeUInt32BE(payloadBuffer.length, 1);
    const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);

    const tryPort = async (portIdx: number): Promise<any> => {
      if (portIdx >= ctx.lsPorts.length) {
        throw new Error('All gRPC ports failed');
      }

      const port = ctx.lsPorts[portIdx];
      const reqOptions = {
        hostname: '127.0.0.1',
        port,
        path: `/exa.language_server_pb.LanguageServerService/${endpoint}`,
        method: 'POST',
        rejectUnauthorized: false,
        timeout: 5000,
        headers: {
          'x-codeium-csrf-token': ctx.csrfToken,
          'content-type': 'application/grpc-web+json',
          'x-grpc-web': '1',
          'content-length': grpcWebBody.length,
          'User-Agent': 'Antigravity-Companion-App'
        }
      };

      return new Promise((resolve, reject) => {
        const req = https.request(reqOptions, (res) => {
          let chunks: Buffer[] = [];
          res.on('data', (d) => chunks.push(Buffer.from(d)));
          res.on('end', () => {
            const body = Buffer.concat(chunks).toString('utf8');
            if (res.statusCode && res.statusCode >= 200 && res.statusCode < 300) {
              try {
                const jsonStr = body.substring(body.indexOf('{'), body.lastIndexOf('}') + 1);
                resolve(JSON.parse(jsonStr));
              } catch (e: any) {
                resolve({ raw: body });
              }
            } else {
              resolve(tryPort(portIdx + 1));
            }
          });
        });

        req.on('error', () => resolve(tryPort(portIdx + 1)));
        req.on('timeout', () => { req.destroy(); resolve(tryPort(portIdx + 1)); });
        req.write(grpcWebBody);
        req.end();
      });
    };

    return tryPort(0);
  }

  // Get active MCP server states
  fastify.get('/mcp', async (request, reply) => {
    try {
      const data = await callLanguageServer('GetMcpServerStates');
      return reply.send({ success: true, ...(data || {}) });
    } catch (err: any) {
      return reply.code(500).send({ success: false, error: err.message });
    }
  });

  // Get all installed/available skills
  fastify.get('/skills', async (request, reply) => {
    try {
      const data = await callLanguageServer('GetAllSkills');
      return reply.send({ success: true, ...(data || {}) });
    } catch (err: any) {
      return reply.code(500).send({ success: false, error: err.message });
    }
  });

  // Get available and installed plugins
  fastify.get('/plugins', async (request, reply) => {
    try {
      const data = await callLanguageServer('GetAvailableCascadePlugins');
      return reply.send({ success: true, ...(data || {}) });
    } catch (err: any) {
      return reply.code(500).send({ success: false, error: err.message });
    }
  });
}
