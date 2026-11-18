# Antigravity Project ID Resolution & gRPC Error Handling

## The Project ID Mapping Problem

When creating a new conversation via the Antigravity gRPC API (`StartCascade`), you must provide a valid `projectId` that corresponds to the active workspace. If you attempt to register a new `projectId` via `CreateProject` using a workspace name that already exists, the Language Server will reject the request.

However, resolving an existing workspace path (e.g. `d:/EduTrack`) to its correct `projectId` is non-trivial because the Antigravity Language Server does not expose a standard gRPC endpoint to list all available projects.

### The Stale ID Trap in `agyhub_summaries_proto.pb`
The backend maintains a binary file containing project metadata and summaries located at:
`~/.gemini/antigravity/agyhub_summaries_proto.pb`

While this file contains the mapping between workspace paths (`file:///d:/EduTrack`) and `projectId` UUIDs (`$9df12238-ac51-4ffb-ab68-737f217d4e03`), **it does not delete old entries**. If a project is removed and re-added, or re-registered under a new ID, multiple stale UUIDs for the exact same workspace will exist in this file. 

Extracting the first UUID found in this file via regex will often result in a stale/obsolete `projectId`. Attempting to pass an obsolete `projectId` into `StartCascade` will result in a fatal `grpc-status: 2 (file does not exist)` error.

### The True Active State in `app_storage.json`
The Antigravity Desktop app (Electron frontend) maintains the true "active" state of known projects in its Local Storage / Preferences equivalent:
`~/.AppData/Roaming/Antigravity/app_storage.json`

This JSON file stores UI states (such as `sidebarCollapsed-<uuid>`) for all currently active projects.

### The Robust Resolution Algorithm
To reliably map a workspace path to its true active `projectId` without relying on local transcript histories, the `relay-server` must perform an intersection search:

1. **Scan `agyhub_summaries_proto.pb`**: Use a regex to extract **all** UUIDs associated with the target workspace path.
   *Note: Ensure both standard (`file:///d:/path`) and URL-encoded (`file:///d%3A/path`) formats are matched.*
2. **Scan `app_storage.json`**: Extract all UUIDs present in the keys or values. This creates a whitelist of actively recognized project IDs.
3. **Intersect**: Find the extracted UUID from Step 1 that exists in the whitelist from Step 2. This guarantees the selected `projectId` is both associated with the workspace and actively recognized by the system.

## The gRPC HTTP 200 Silent Failure Trap

Antigravity communicates via gRPC-Web over HTTP/1.1 or HTTP/2. A critical nuance of the gRPC protocol is that **HTTP 200 OK does not mean the RPC call succeeded**.

When a request like `CreateProject` fails because the project name is taken, the backend returns:
- **HTTP Status**: 200 OK
- **HTTP Headers**: `grpc-status: 6`, `grpc-message: "already_exists..."`

If a standard HTTP client only checks `response.statusCode >= 200`, it will falsely assume the gRPC call succeeded and proceed with invalid data, leading to downstream cascading failures. 

**Fix**: Any client interacting with Antigravity's gRPC layer must explicitly read the `grpc-status` header (or trailers) and treat any non-zero value as a hard failure.
