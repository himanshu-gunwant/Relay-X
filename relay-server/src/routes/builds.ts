import { FastifyInstance } from 'fastify';
import { BuildDetectorService } from '../services/build-detector';
import { config } from '../config';
import * as fsPromises from 'fs/promises';
import * as path from 'path';

export async function buildRoutes(
  fastify: FastifyInstance,
  options: { buildDetector: BuildDetectorService; ctx: any }
) {
  const { buildDetector, ctx } = options;

  fastify.get('/', async (request, reply) => {
    const { workspace } = request.query as { workspace?: string };
    if (!workspace) {
      return reply.status(400).send({ error: 'workspace query parameter is required' });
    }
    const builds = await buildDetector.scanWorkspace(workspace);
    return reply.send(builds.map(b => ({
      ...b,
      downloadUrl: `/api/builds/${b.id}/download?workspace=${encodeURIComponent(workspace)}`,
    })));
  });

  fastify.get('/:id/download', async (request, reply) => {
    const { id } = request.params as { id: string };
    const { workspace } = request.query as { workspace?: string };
    if (!workspace) {
      return reply.status(400).send({ error: 'workspace query parameter is required' });
    }

    let build = buildDetector.getBuild(id);
    if (!build) {
      // Re-scan workspace if in-memory cache was lost (e.g. server restart)
      await buildDetector.scanWorkspace(workspace);
      build = buildDetector.getBuild(id);
    }
    if (!build) return reply.status(404).send({ error: 'Build not found' });

    try {
      const realPath = await fsPromises.realpath(build.absolutePath);
      // Normalize slashes for Windows compatibility
      const normRealPath = path.resolve(realPath).replace(/\\/g, '/').toLowerCase();
      const normWorkspace = path.resolve(workspace).replace(/\\/g, '/').toLowerCase();

      if (!normRealPath.startsWith(normWorkspace)) {
        return reply.status(403).send({ error: 'Path traversal blocked' });
      }

      const fileName = path.basename(realPath);
      const dirName = path.dirname(realPath);

      // Using @fastify/static sendFile handles backpressure, range requests, and safe streaming
      return (reply as any)
        .header('Content-Disposition', `attachment; filename="${build.fileName}"`)
        .sendFile(fileName, dirName);
    } catch (e: any) {
      return reply.status(500).send({ error: 'Failed to read artifact', details: e.message });
    }
  });

  fastify.get('/raw', async (request, reply) => {
    const { path: reqPath, workspace } = request.query as { path?: string; workspace?: string };
    if (!reqPath) {
      return reply.status(400).send({ error: 'path query parameter is required' });
    }
    const wsDir = workspace ? path.resolve(workspace) : (ctx?.workspaceDir || config.workspaceDir || process.cwd());
    
    // Support file:/// links or relative paths
    let cleanPath = reqPath;
    if (cleanPath.startsWith('file:///')) {
      cleanPath = decodeURIComponent(cleanPath.replace(/^file:\/\/\/?/, ''));
    }

    const fullPath = path.isAbsolute(cleanPath) ? path.resolve(cleanPath) : path.resolve(wsDir, cleanPath);
    const normFullPath = fullPath.replace(/\\/g, '/').toLowerCase();
    const normWsDir = wsDir.replace(/\\/g, '/').toLowerCase();

    if (!normFullPath.startsWith(normWsDir)) {
      return reply.status(403).send({ error: 'Path traversal blocked' });
    }

    try {
      const realPath = await fsPromises.realpath(fullPath);
      const stat = await fsPromises.stat(realPath);
      if (!stat.isFile()) {
        return reply.status(400).send({ error: 'Target is not a file' });
      }

      const fileName = path.basename(realPath);
      const dirName = path.dirname(realPath);

      return (reply as any)
        .header('Content-Disposition', `attachment; filename="${fileName}"`)
        .sendFile(fileName, dirName);
    } catch (e: any) {
      return reply.status(500).send({ error: 'Failed to read file', details: e.message });
    }
  });
}
