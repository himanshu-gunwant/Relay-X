# Relay-X

[![GitHub stars](https://img.shields.io/github/stars/himanshu-gunwant/Relay-X?style=flat-square)](https://github.com/himanshu-gunwant/Relay-X/stargazers)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=flat-square)](LICENSE)
[![Author](https://img.shields.io/badge/Author-Himanshu%20Gunwant-black?style=flat-square&logo=github)](https://github.com/himanshu-gunwant)

Relay-X is a cross-device bridge for connecting, controlling, and extending AI coding agents remotely.

---

## Overview

Relay-X bridges desktop AI coding workflows with remote mobile management and telemetry. The system is split into two primary components:

1. **Relay-X Server & CLI (`relay-server/`)**: A TypeScript service and CLI tool powered by Fastify and WebSockets that discovers host coding agent runtimes, monitors workspace transcripts, watches file changes, detects builds, and sends push notifications via Firebase Cloud Messaging.
2. **Relay-X Mobile Client (`mobile_app/`)**: A cross-platform Flutter application providing real-time task inspection, agent chat interaction, workspace file browsing, git status tracking, hardware telemetry, and Wake-on-LAN controls.

---

## Core Capabilities

- **Real-Time Task & Chat Feed**: Stream agent actions, reasoning steps, tool executions, and file modifications in real time over WebSockets.
- **Interactive Agent Communication**: Send prompts, upload reference photos, and review agent diffs straight from mobile.
- **Workspace File Explorer**: Inspect project directory trees, review modified files, and inspect line diffs.
- **Build Monitoring & Artifact Delivery**: Automatically detects Android APK and Node build runs, notifying you upon build completion.
- **Hardware Telemetry & Remote Control**: Real-time CPU, RAM, and temperature metrics, paired with Wake-on-LAN (WOL) capabilities to manage the host workstation.
- **Security & Privacy**: Authenticated communication protected by bcrypt-hashed pre-shared API keys and tokenized sessions.
- **Unified CLI Tool (`relay-x`)**: Control, monitor, and configure the bridge directly from your terminal.

---

## Project Structure

```text
Relay-X/
├── mobile_app/            # Flutter mobile application
│   ├── assets/            # Brand visual assets (Relay-X logo & icons)
│   ├── lib/               # App sources (screens, providers, services)
│   ├── android/           # Android platform configuration
│   └── pubspec.yaml       # Flutter dependencies & metadata
├── relay-server/          # Node.js backend relay & CLI executable
│   ├── src/               # TypeScript sources (routes, bootstrap, services)
│   ├── credentials/       # Local credential store (git-ignored)
│   └── package.json       # Node dependencies & CLI configuration
├── docs/                  # Project technical documentation & research
└── README.md
```

---

## Getting Started

### 1. Prerequisites

- **Node.js**: v20 or higher
- **Flutter SDK**: v3.12 or higher (Dart SDK 3.12+)
- **Android Device / Emulator**: Running Android 8.0 (API 26) or higher
- **Desktop Agent Runtime**: Active coding agent or IDE (e.g. Google Antigravity) installed on host workstation

---

### 2. Relay-X CLI & Server Setup

Navigate into `relay-server` and install dependencies:

```bash
cd relay-server
npm install
```

Build the TypeScript source and link the CLI globally:

```bash
npm run build
npm link
```

Once linked, the `relay-x` CLI is available globally in your terminal.

#### CLI Usage

```bash
# Display help and usage information
relay-x --help

# Show current version
relay-x --version

# Run the automated security setup and generate an API key
relay-x setup

# Check if the Relay-X server and agent are active
relay-x status

# Start the Relay-X server daemon
relay-x start
```

#### Environment Configuration

The `relay-x setup` command automatically generates a `.env` file. You can also manually configure `.env` using `.env.example`:

```bash
cp .env.example .env
```

| Variable | Description | Default |
| :--- | :--- | :--- |
| `PORT` | Listening port for the Fastify HTTP & WebSocket server | `3579` |
| `API_KEY_HASH` | Bcrypt hash of your pre-shared secret key for client auth | *(required)* |
| `WORKSPACE_DIR` | Absolute path to the active code repository on your host | Current directory |
| `FIREBASE_SERVICE_ACCOUNT_PATH` | Path to Firebase admin JSON service account for push alerts | `credentials/firebase-service-account.json` |
| `ANTIGRAVITY_EXE_PATH` | Path to the desktop agent executable on Windows | Autodetected via `%LOCALAPPDATA%` |

#### Running the Server

Start the server using the CLI:

```bash
relay-x
# or: relay-x start
```

For live reloading during development:

```bash
npm run dev
```

---

### 3. Mobile App Setup

Navigate into the `mobile_app` folder and install package dependencies:

```bash
cd mobile_app
flutter pub get
```

#### Run the Application

Connect your physical Android device via USB (or start an Android Virtual Device) and launch the app:

```bash
flutter run
```

#### Build a Release APK

To create an optimized standalone release build:

```bash
flutter build apk --release
```

The resulting binary will be located at `mobile_app/build/app/outputs/flutter-apk/app-release.apk`.

---

## Connecting Mobile to Workstation

1. Verify that your mobile device is on the same local network (or VPN/tailnet) as your host workstation.
2. Launch **Relay-X** on your phone.
3. In the setup / login screen:
   - **Relay Server URL**: Enter your workstation's IP (e.g. `http://192.168.1.100:3579`).
   - **Your Name**: Your preferred display name.
   - **API Key**: Enter the plain-text API key generated during `relay-x setup`.
4. Tap **Connect** to establish real-time bridge connectivity.

---

## Security Practices

- **Never Commit Secrets**: Do not track `.env` files, Firebase service account keys, or authentication tokens in version control.
- **Firewall Rules**: Ensure inbound traffic on port `3579` is permitted across your private local network only.
- **Reverse Proxy / Tailscale**: For access outside your local network, place the relay server behind a secure tunnel (such as Tailscale or WireGuard) with SSL/TLS termination.

---

## Contributing

Contributions, bug reports, and suggestions are welcome. Please open an issue or pull request on GitHub.

---

## Author & Maintainer

Developed and maintained by **Himanshu Gunwant**.

- GitHub: [@himanshu-gunwant](https://github.com/himanshu-gunwant)
- Email: [hello@himanshugunwant.com](mailto:hello@himanshugunwant.com)
- Profile: [https://github.com/himanshu-gunwant](https://github.com/himanshu-gunwant)

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for full license details.
