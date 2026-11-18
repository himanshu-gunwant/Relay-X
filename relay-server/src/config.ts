import dotenv from 'dotenv';
import path from 'path';
import os from 'os';
import { z } from 'zod';

export const APP_ROOT = path.resolve(__dirname, '..');

dotenv.config({ path: path.join(APP_ROOT, '.env'), override: true });

const defaultAntigravityPath = process.env.LOCALAPPDATA
  ? path.join(process.env.LOCALAPPDATA, 'Programs', 'antigravity', 'Antigravity.exe')
  : path.join(os.homedir(), 'AppData', 'Local', 'Programs', 'antigravity', 'Antigravity.exe');

const configSchema = z.object({
  PORT: z.coerce.number().default(3579),
  WORKSPACE_DIR: z.string().default(process.cwd()),
  API_KEY_HASH: z.string().default(''),
  FIREBASE_SERVICE_ACCOUNT_PATH: z.string().default('credentials/firebase-service-account.json'),
  ANTIGRAVITY_EXE_PATH: z.string().default(defaultAntigravityPath),
  RELAY_X_AGENT_EXE_PATH: z.string().optional(),
});

const parsed = configSchema.safeParse(process.env);

if (!parsed.success) {
  console.error('Configuration validation error:', parsed.error.format());
  process.exit(1);
}

export const config = {
  port: parsed.data.PORT,
  workspaceDir: path.resolve(parsed.data.WORKSPACE_DIR),
  apiKeyHash: parsed.data.API_KEY_HASH,
  firebaseServiceAccountPath: path.resolve(APP_ROOT, parsed.data.FIREBASE_SERVICE_ACCOUNT_PATH),
  antigravityExePath: parsed.data.RELAY_X_AGENT_EXE_PATH || parsed.data.ANTIGRAVITY_EXE_PATH,
};
