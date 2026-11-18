import path from 'path';
import * as https from 'https';
import { AntigravityContext } from './types';
import {
  findLanguageServerPid,
  getProcessCommandLine,
  parseCsrfToken,
  parseIdeVersion,
  findListeningPort,
  readProjectId,
  readCdpEndpoint
} from '../utils/process';

async function prioritizePorts(ports: number[], csrfToken: string): Promise<number[]> {
  const payloadBuffer = Buffer.from('{}', 'utf8');
  const frameHeader = Buffer.alloc(5);
  frameHeader.writeUInt8(0, 0);
  frameHeader.writeUInt32BE(payloadBuffer.length, 1);
  const grpcWebBody = Buffer.concat([frameHeader, payloadBuffer]);

  const probe = (port: number): Promise<boolean> => {
    return new Promise((resolve) => {
      const req = https.request({
        hostname: '127.0.0.1',
        port,
        path: '/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary',
        method: 'POST',
        rejectUnauthorized: false,
        timeout: 1000,
        headers: {
          'x-codeium-csrf-token': csrfToken,
          'content-type': 'application/grpc-web+json',
          'x-grpc-web': '1',
          'content-length': grpcWebBody.length
        }
      }, res => {
        resolve(res.statusCode === 200);
      });
      req.on('error', () => resolve(false));
      req.on('timeout', () => { req.destroy(); resolve(false); });
      req.write(grpcWebBody);
      req.end();
    });
  };

  try {
    const results = await Promise.all(ports.map(async p => ({ port: p, ok: await probe(p) })));
    const working = results.filter(r => r.ok).map(r => r.port);
    const others = results.filter(r => !r.ok).map(r => r.port);
    return working.length > 0 ? [...working, ...others] : ports;
  } catch {
    return ports;
  }
}

export async function discover(workspaceDir: string): Promise<AntigravityContext> {
  const pid = await findLanguageServerPid();
  const cmdLine = await getProcessCommandLine(pid);
  
  const csrfToken = parseCsrfToken(cmdLine);
  const ideVersion = parseIdeVersion(cmdLine);
  
  const rawPorts = await findListeningPort(pid);
  const lsPorts = await prioritizePorts(rawPorts, csrfToken);
  
  const projectId = await readProjectId();
  const cdpWsUrl = await readCdpEndpoint();
  
  const userProfile = process.env.USERPROFILE || '';
  const agentapiBat = path.join(userProfile, '.gemini', 'antigravity', 'bin', 'agentapi.bat');
  const brainDir = path.join(userProfile, '.gemini', 'antigravity', 'brain');
  
  return {
    pid,
    csrfToken,
    lsPorts,
    projectId,
    agentapiBat,
    brainDir,
    workspaceDir,
    cdpWsUrl,
    ideVersion,
    discoveredAt: new Date()
  };
}
