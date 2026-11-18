# Relay-X - Relay Server & CLI

The backend service and CLI tool for the Relay-X cross-device agent bridge, built with Node.js and TypeScript.

## Purpose
The Relay-X server acts as the central hub for discovering local agent runtimes, managing active workspaces, routing WebSocket events, streaming terminal sessions, and dispatching push notifications to the mobile client.

## CLI Usage
Relay-X can be run as a globally linked CLI command:

```bash
# Display help and available commands
relay-x --help

# Show current version
relay-x --version

# Run the guided security & API key setup
relay-x setup

# Check daemon health and agent connectivity
relay-x status

# Start the server daemon
relay-x start
```

## Architecture
The server is built on Node.js using Fastify and WebSockets for high-performance, real-time communication. It securely authenticates mobile client requests and bridges local developer workspaces.

## Environment Variables
Create a `.env` file in the root of the `relay-server` directory using `.env.example` as a template (or run `relay-x setup` to generate one automatically).

Required variables:
- `API_KEY_HASH`: The bcrypt hash of your API key used for authenticating the mobile client.
- `WORKSPACE_DIR`: The absolute path to your active workspace directory.
- `PORT`: (Optional) Server port, defaults to `3579`.
- `ANTIGRAVITY_EXE_PATH` / `RELAY_X_AGENT_EXE_PATH`: (Optional) Path to the host desktop agent executable.

## Setup Instructions
1. Navigate to the `relay-server` directory.
2. Install dependencies:
   ```bash
   npm install
   ```
3. Run the setup command:
   ```bash
   npm run setup
   # or: relay-x setup
   ```
4. **Credentials Setup**: Create a folder named `credentials/profiles` within the `relay-server` directory if needed for multi-account management:
   ```bash
   mkdir -p credentials/profiles
   ```
5. **Firebase Configuration**: Ensure you have a valid Firebase service account JSON placed in `credentials/firebase-service-account.json` if push alerts are required.

## Running Locally
To start the server for local development:
```bash
npm run dev
# or: relay-x
```

## Production Deployment
For production, run the server using PM2 or the included Windows Scheduled Task scripts:
```bash
npm install -g pm2
pm2 start dist/index.js --name "relay-x"
```

## Troubleshooting
- **Cannot connect from mobile**: Check that the server is binding to `0.0.0.0` and that Windows Firewall allows inbound connections on port `3579`.
- **Authentication Failures**: Verify that the `API_KEY_HASH` in `.env` matches the plain API key entered in your mobile app settings.
