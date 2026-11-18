#!/usr/bin/env node
import Fastify from 'fastify';
import { spawn } from 'child_process';
import { discover } from './bootstrap/discovery.js';
import { AgentapiService } from './services/agentapi.js';
import { HealthMonitor } from './bootstrap/health.js';
import { config } from './config.js';
import { authMiddleware } from './middleware/auth.js';
import { conversationsRoutes } from './routes/conversations.js';
import { wsRoutes } from './routes/ws.js';
import { TranscriptWatcherService } from './services/transcript-watcher.js';
import { FileWatcherService } from './services/file-watcher.js';
import { GitService } from './services/git.js';
import { filesRoutes } from './routes/files.js';
import { gitRoutes } from './routes/git.js';
import { systemRoutes } from './routes/system.js';
import { BuildDetectorService } from './services/build-detector.js';
import { NotificationService } from './services/notification.js';
import { buildRoutes } from './routes/builds.js';
import { notificationRoutes } from './routes/notifications.js';
import { accountsRoute } from './routes/accounts.js';
import { workspacesRoutes } from './routes/workspaces.js';
import { workspacesGrpcRoutes } from './routes/workspaces-grpc.js';
import { HardwareMonitorService, getPrimaryMacAddress } from './services/hardware-monitor.js';
import { hardwareRoutes } from './routes/hardware.js';
import { customizationsRoutes } from './routes/customizations.js';
import fastifyWebsocket from '@fastify/websocket';
import fastifyStatic from '@fastify/static';
import { errorHandler } from './middleware/error-handler.js';
import { setup } from './setup.js';
import fs from 'fs';
import path from 'path';
import { APP_ROOT } from './config.js';

// CLI Argument Handling and Entry Point
async function runCli() {
  const args = process.argv.slice(2);

  if (args.includes('-v') || args.includes('--version') || args.includes('version')) {
    console.log('relay-x v1.2.1');
    process.exit(0);
  }

  if (args.includes('-h') || args.includes('--help') || args.includes('help')) {
    console.log(`
  ____      _             __  __
 |  _ \\ ___| | __ _ _   _ \\ \\/ /
 | |_) / _ \\ |/ _\` | | | | \\  / 
 |  _ <  __/ | (_| | |_| | /  \\ 
 |_| \\_\\___|_|\\__,_|\\__, |/_/\\_\\
                    |___/       

Relay-X v1.2.1
Cross-device bridge for connecting, controlling, and extending AI coding agents remotely.

Usage:
  relay-x [command] [options]

Commands:
  start             Start the Relay-X server daemon (default)
  setup             Initialize environment configuration and generate API key
  status            Check the status of running agent and relay server
  version           Display current version

Options:
  -p, --port <port>       Port to listen on (default: 3579 or $PORT)
  -w, --workspace <path>  Workspace directory to monitor (default: current directory or $WORKSPACE_DIR)
  -h, --help              Show this help message
  -v, --version           Show version information

Documentation:
  https://github.com/himanshu-gunwant/Relay-X#readme
`);
    process.exit(0);
  }

  if (args.includes('setup')) {
    try {
      await setup();
      process.exit(0);
    } catch (err) {
      console.error('[Relay-X Setup Error]:', err);
      process.exit(1);
    }
  }

  if (args.includes('status')) {
    const port = process.env.PORT || 3579;
    try {
      const res = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (res.ok) {
        const data = await res.json() as any;
        console.log('==================================================');
        console.log('                 Relay-X Status                   ');
        console.log('==================================================');
        console.log(`Server Status:   ONLINE`);
        console.log(`Listening Port:  ${port}`);
        console.log(`Agent PID:       ${data.antigravityPid || 'N/A'}`);
        console.log(`Agent Version:   ${data.antigravityVersion || 'N/A'}`);
        console.log(`Workspace:       ${data.workspace || 'N/A'}`);
        console.log(`Discovered:      ${data.discoveredAt || 'N/A'}`);
        console.log('==================================================');
        process.exit(0);
      } else {
        console.log(`Relay-X server responded with HTTP status ${res.status}`);
        process.exit(1);
      }
    } catch (_) {
      console.log(`Relay-X daemon is NOT running on port ${port}.`);
      console.log('Run "relay-x" or "relay-x start" to launch the server.');
      process.exit(1);
    }
  }

  await main();
}

async function main() {
  // Startup Diagnostics and Validation
  let envPath = path.join(APP_ROOT, '.env');
  if (!fs.existsSync(envPath) && fs.existsSync(path.join(process.cwd(), '.env'))) {
    envPath = path.join(process.cwd(), '.env');
  }
  const profilesDir = path.join(APP_ROOT, 'credentials', 'profiles');

  if (!fs.existsSync(envPath)) {
    console.error(`[Relay-X Fatal] Missing Environment File: ${envPath}`);
    console.error(`Run "relay-x setup" to generate configuration and API credentials.`);
    process.exit(1);
  }

  if (!fs.existsSync(profilesDir)) {
    fs.mkdirSync(profilesDir, { recursive: true });
  }

  console.log('==================================================');
  console.log('                 Relay-X Daemon                   ');
  console.log('     Cross-Device Bridge for AI Coding Agents     ');
  console.log('==================================================');
  console.log(`[Relay-X] App Root: ${APP_ROOT}`);
  console.log(`[Relay-X] Environment: ${envPath}`);
  console.log(`[Relay-X] Profiles Directory: ${profilesDir}`);

  const fastify = Fastify({
    routerOptions: {
      ignoreTrailingSlash: true
    },
    logger: {
      transport: {
        target: 'pino-pretty',
        options: {
          colorize: true
        }
      }
    }
  });

  // Register global error handler
  fastify.setErrorHandler(errorHandler);

  // Allow empty JSON bodies without throwing FST_ERR_CTP_EMPTY_JSON_BODY
  fastify.addContentTypeParser('application/json', { parseAs: 'string' }, (req, body: string, done) => {
    if (!body || body.trim() === '') {
      done(null, {});
      return;
    }
    try {
      const json = JSON.parse(body);
      done(null, json);
    } catch (err: any) {
      err.statusCode = 400;
      done(err, undefined);
    }
  });
  try {
    console.log('[Bootstrap] Discovering Antigravity runtime...');
    let ctx;
    try {
      ctx = await discover(config.workspaceDir);
      console.log(`[Bootstrap] Successfully discovered Antigravity! PID: ${ctx.pid}, Ports: ${ctx.lsPorts.join(', ')}, Project ID: ${ctx.projectId}`);
    } catch (e) {
      console.log('[Bootstrap] Antigravity not found running. Attempting to auto-start it...');
      
      const { spawn } = await import('child_process');
      const os = await import('os');
      const path = await import('path');
      
      const appDataLocal = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
      const execPath = path.join(appDataLocal, 'Programs', 'antigravity', 'Antigravity.exe');
      
      try {
        const p = spawn(execPath, [], { detached: true, shell: true, stdio: 'ignore' });
        p.unref(); // Allow the relay server to exit independently
        console.log(`[Bootstrap] Spawning Antigravity daemon from ${execPath}... waiting for it to initialize...`);
        
        // Wait up to 10 seconds for it to start and become discoverable
        let retries = 10;
        while (retries > 0) {
          await new Promise(resolve => setTimeout(resolve, 1000));
          try {
            ctx = await discover(config.workspaceDir);
            console.log(`[Bootstrap] Successfully discovered Antigravity after auto-start! PID: ${ctx.pid}`);
            break;
          } catch (err) {
            retries--;
          }
        }
      } catch (spawnErr) {
        console.error('[Bootstrap] Failed to auto-start daemon:', spawnErr);
      }

      if (!ctx) {
        console.log('[Bootstrap] Antigravity failed to start in time. Starting in standalone/listening mode.');
        ctx = {
          pid: 0,
          csrfToken: '',
          lsPorts: [],
          projectId: '',
          agentapiBat: '',
          brainDir: path.join(os.homedir(), '.gemini', 'antigravity', 'brain'),
          workspaceDir: config.workspaceDir,
          cdpWsUrl: null,
          ideVersion: '',
          discoveredAt: new Date(0)
        };
      }
    }

    // Initialize and start services
    const agentapi = new AgentapiService();
    const transcripts = new TranscriptWatcherService();
    const fileWatcher = new FileWatcherService();
    const gitService = new GitService();
    const buildDetector = new BuildDetectorService();
    const notificationService = new NotificationService();
    const hardwareMonitor = new HardwareMonitorService();
    const healthMonitor = new HealthMonitor([agentapi, transcripts, fileWatcher, gitService, buildDetector, notificationService, hardwareMonitor]);

    await agentapi.start(ctx);
    await transcripts.start(ctx);
    await fileWatcher.start(ctx);
    await gitService.start(ctx);
    await buildDetector.start(ctx);
    await notificationService.start(ctx);
    await hardwareMonitor.start(ctx);
    await healthMonitor.start(ctx);

    // Event hooks
    transcripts.on('transcript:step', (conversationId, event) => {
      notificationService.onTranscriptEvent(conversationId, event);
    });

    healthMonitor.on('daemon:status', (isActive) => {
      if (fastify.websocketServer) {
        for (const client of fastify.websocketServer.clients) {
          if (client.readyState === 1 /* OPEN */) {
            client.send(JSON.stringify({ type: 'daemon_status', data: { active: isActive } }));
          }
        }
      }
    });

    // Register websocket support
    await fastify.register(fastifyWebsocket);

    // Register static file serving plugin for safe streaming, range requests, and downloads
    await fastify.register(fastifyStatic, {
      root: path.resolve(config.workspaceDir),
      serve: false,
    });

    // Public test notification endpoint for testing the pipeline manually
    fastify.post('/api/test-notification', async (request, reply) => {
      const body = (request.body as any) || {};
      const title = body.title || 'Relay-X Test';
      const text = body.body || 'This is a test notification from the server!';
      const category = body.category || 'apk_ready';

      notificationService.dispatch({
        category,
        title,
        body: text,
        priority: 'high',
        deduplicationKey: `test_${Date.now()}`
      });
      return { success: true, message: 'Notification dispatched' };
    });

    fastify.post('/api/system/restart-daemon', async (request, reply) => {
      const body = (request.body as any) || {};
      const execPath = body.executablePath;
      if (!execPath) {
        return reply.code(400).send({ success: false, error: 'executablePath is required' });
      }
      
      // Security fix: strictly validate the path
      if (execPath !== config.antigravityExePath) {
        return reply.code(403).send({ success: false, error: 'Unauthorized executable path' });
      }

      console.log(`[System] Attempting to manually restart daemon...`);
      try {
        // Attempt to kill existing process first if it's frozen
        try {
          const { findLanguageServerPid } = await import('./utils/process.js');
          const { exec } = await import('child_process');
          const { promisify } = await import('util');
          const execAsync = promisify(exec);
          
          const pid = await findLanguageServerPid();
          console.log(`[System] Found frozen/existing daemon at PID ${pid}. Killing it...`);
          await execAsync(`taskkill /F /PID ${pid}`);
          // Wait a second for ports to clear
          await new Promise(resolve => setTimeout(resolve, 1000));
        } catch (e: any) {
          console.log(`[System] No existing daemon found to kill, proceeding to spawn.`);
        }

        console.log(`[System] Spawning fresh daemon from: ${execPath}`);
        const p = spawn(execPath, [], { detached: true, stdio: 'ignore' });
        p.unref(); // allow the relay server to exit independently
        return { success: true };
      } catch (err: any) {
        console.error('[System] Failed to spawn daemon:', err);
        return reply.code(500).send({ success: false, error: err.message });
      }
    });

    fastify.get('/api/quota', async (request, reply) => {
      const result = await agentapi.getQuotaSummary();
      if (!result.success) {
        reply.code(500).send(result.error);
        return;
      }
      return result.data;
    });

    // Register authentication middleware
    fastify.addHook('preHandler', authMiddleware);

    // Register routes
    fastify.register(conversationsRoutes, {
      prefix: '/api/conversations',
      agentapi,
      transcripts,
      ctx
    });

    fastify.register(systemRoutes, {
      prefix: '/api/system',
      ctx
    });

    fastify.register(filesRoutes, {
      prefix: '/api/files',
      ctx,
      transcripts,
      fileWatcher
    });

    fastify.register(gitRoutes, {
      prefix: '/api/git',
      gitService,
      transcripts,
      ctx
    });

    fastify.register(buildRoutes, {
      prefix: '/api/builds',
      buildDetector,
      ctx
    });

    fastify.register(notificationRoutes, {
      prefix: '/api/notifications',
      notificationService
    });

    fastify.register(accountsRoute, {
      prefix: '/api/accounts'
    });

    fastify.register(workspacesRoutes, {
      prefix: '/api/workspaces',
      agentapi
    });

    fastify.register(workspacesGrpcRoutes, {
      prefix: '/api/workspaces-grpc',
      ctx
    });

    fastify.register(hardwareRoutes, {
      prefix: '/api/hardware',
      hardwareMonitor
    });

    fastify.register(customizationsRoutes, {
      prefix: '/api/customizations',
      ctx
    });

    fastify.register(wsRoutes, {
      transcripts,
      fileWatcher,
      gitService,
      buildDetector,
      hardwareMonitor
    });

    fastify.get('/api/health', async (request, reply) => {
      return {
        status: 'connected',
        service: 'Relay-X',
        version: '1.2.1',
        antigravityPid: ctx.pid,
        antigravityVersion: ctx.ideVersion,
        workspace: ctx.workspaceDir,
        discoveredAt: ctx.discoveredAt,
        macAddress: getPrimaryMacAddress(),
      };
    });

    // Handle clean shutdown
    let shuttingDown = false;
    const cleanup = async () => {
      if (shuttingDown) return;
      shuttingDown = true;
      console.log('[Relay-X] Shutting down server...');
      await buildDetector.stop();
      await notificationService.stop();
      await fileWatcher.stop();
      await gitService.stop();
      await transcripts.stop();
      await hardwareMonitor.stop();
      await healthMonitor.stop();
      await agentapi.stop();
      await fastify.close();
      console.log('[Relay-X] Server shut down cleanly.');
      process.exit(0);
    };

    process.on('SIGINT', cleanup);
    process.on('SIGTERM', cleanup);

    await fastify.listen({ port: config.port, host: '0.0.0.0' });
    console.log(`[Relay-X] Server listening on port ${config.port}`);
  } catch (err) {
    console.error('Fatal bootstrap error:', err);
    process.exit(1);
  }
}

runCli();
