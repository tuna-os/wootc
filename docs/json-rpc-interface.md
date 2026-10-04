# wootc JSON-RPC 2.0 Interface

The `wootc.exe serve` command starts a JSON-RPC 2.0 server over standard input/output. This interface enables:
- WinUI 3 shell communication with the Go engine
- Headless testing and automation
- Component testing without the full GUI

**Current status** (2026-10-02): Phase A merged; Go engine supports `serve` with 20 RPC methods. Phase B (native component testing) is in progress.

---

## Launching the server

```bash
wootc.exe serve
```

The server:
- Reads JSON-RPC requests from stdin (one complete JSON object per line)
- Writes JSON-RPC responses and notifications to stdout
- Writes diagnostics and logs to stderr
- Operates in a single stdio session until Shutdown is called or the connection closes

### Prerequisites

- Run from an elevated (Administrator) context for full functionality
- Caller must handle authentication (see [Peer Authentication](#peer-authentication) below)
- stderr must be available for diagnostics

---

## JSON-RPC 2.0 Protocol

Requests and responses follow [JSON-RPC 2.0 specification](https://www.jsonrpc.org/specification).

### Request format

```json
{
  "jsonrpc": "2.0",
  "id": "<caller-provided-id>",
  "method": "<method-name>",
  "params": { /* method-specific parameters */ }
}
```

- `jsonrpc`: Always `"2.0"`
- `id`: Optional string or number; echoed in the response
- `method`: One of the methods listed below
- `params`: Optional object; structure depends on the method

### Response format (success)

```json
{
  "jsonrpc": "2.0",
  "id": "<echo of request id>",
  "result": { /* method-specific result */ }
}
```

### Response format (error)

```json
{
  "jsonrpc": "2.0",
  "id": "<echo of request id>",
  "error": {
    "code": -32600,
    "message": "Invalid Request",
    "data": { /* optional diagnostic details */ }
  }
}
```

### Notifications (from server)

The server may emit JSON-RPC notifications (requests without an `id`):

```json
{
  "jsonrpc": "2.0",
  "method": "<notification-name>",
  "params": { /* notification-specific data */ }
}
```

Notifications indicate state changes, progress, or events that the client should observe.

---

## Peer Authentication

**Important**: The current implementation (Phase A) does not enforce authentication between native peers or shell acceptance. This is addressed in Phase B.

When implemented, authentication will cover:
- Process identity verification (via Windows process handles and tokens)
- Session and SID binding
- Protocol version and build identity exchange
- Rejection of incompatible pairs before any mutation

See [winui-shell.md](winui-shell.md#correct-elevation-and-transport) for the authentication design.

---

## Available Methods

All 20 methods are defined in `app/serve.go`. The source of truth for this list is `ProtocolMethods`.

### Assessment & System Info

#### GetSupportPolicy

Evaluate system hardware and requirements for Linux installation.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "method": "GetSupportPolicy"
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": "1",
  "result": {
    "blocks": [ /* list of blocking issues */ ],
    "warnings": [ /* list of warnings */ ]
  }
}
```

#### GetSystemInfo

Retrieve host system information (OS version, disk capacity, etc.).

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "2",
  "method": "GetSystemInfo"
}
```

#### GetBranding

Get branding information (name, colors, assets) for the current installation.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "3",
  "method": "GetBranding"
}
```

#### GetReleaseNotice

Retrieve the current release notes or notices.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "4",
  "method": "GetReleaseNotice"
}
```

#### GetImages

List available bootc images for installation.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "5",
  "method": "GetImages"
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": "5",
  "result": {
    "images": [
      {
        "name": "Fedora Kinoite",
        "registry": "ghcr.io/...",
        "tag": "latest"
      }
      /* ... more images ... */
    ]
  }
}
```

### Installation & Configuration

#### GetInstallSteps

Get the planned installation steps for a chosen configuration.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "6",
  "method": "GetInstallSteps",
  "params": {
    "image": "<image-reference>",
    "password": "<user-password>"
  }
}
```

#### StartInstall

Begin the installation process with a given configuration.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "7",
  "method": "StartInstall",
  "params": {
    "image": "<image-reference>",
    "password": "<password>",
    "encryption": "tpm2"
  }
}
```

#### CancelInstall

Cancel an in-progress installation.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "8",
  "method": "CancelInstall"
}
```

#### GetStatus

Poll the current installation or operation status.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "9",
  "method": "GetStatus"
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": "9",
  "result": {
    "state": "armed|deploying|ready|graduated",
    "progress": 45,
    "currentStep": "Writing root.disk",
    "elapsed": "00:05:30"
  }
}
```

### Migration & Sessions

#### GetSessionCandidates

Discover browser profiles, app sessions, and user data available for migration.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "10",
  "method": "GetSessionCandidates"
}
```

#### GetUninstallInfo

Get information about the current installation for uninstall planning.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "11",
  "method": "GetUninstallInfo"
}
```

### Boot & Recovery

#### BootIntoLinux

Prepare a one-shot boot into the Linux system.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "12",
  "method": "BootIntoLinux"
}
```

#### GetRecoveryVerdict

Retrieve recovery options for a failed installation or boot state.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "13",
  "method": "GetRecoveryVerdict"
}
```

#### GetLastRun

Get information about the last installation attempt or session.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "14",
  "method": "GetLastRun"
}
```

#### ExistingInstallFound

Check if an existing wootc installation is detected.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "15",
  "method": "ExistingInstallFound"
}
```

#### UninstallWith

Initiate uninstall with specified preservation options.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "16",
  "method": "UninstallWith",
  "params": {
    "preserveData": true,
    "removeBoot": true
  }
}
```

### Maintenance & Utilities

#### DefragDrive

Defragment the root.disk file (on filesystems that support it).

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "17",
  "method": "DefragDrive"
}
```

#### Reboot

Prepare and trigger a system reboot.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "18",
  "method": "Reboot"
}
```

### Testing & E2E

#### E2EDriveDirective

(E2E test only) Inject a test directive into the running installation.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "19",
  "method": "E2EDriveDirective",
  "params": {
    "directive": "<test-instruction>"
  }
}
```

#### E2EDriveReport

(E2E test only) Report test results and verification data.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "20",
  "method": "E2EDriveReport",
  "params": {
    "passed": true,
    "evidence": { /* test details */ }
  }
}
```

### Lifecycle

#### Shutdown

Gracefully shut down the server and exit.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": "21",
  "method": "Shutdown"
}
```

The server will:
1. Complete any in-flight operations
2. Persist recovery state
3. Exit cleanly

---

## Error Codes

| Code | Meaning |
|---|---|
| -32700 | Parse error — malformed JSON |
| -32600 | Invalid Request — missing required fields |
| -32601 | Method not found — unknown method name |
| -32602 | Invalid params — parameter types/values incorrect |
| -32603 | Internal error — server-side failure |

---

## Testing & Examples

### Using curl (Linux test environment)

```bash
# Start the server in one terminal
wootc.exe serve

# In another, send requests via named pipe or socket (platform-dependent)
echo '{"jsonrpc":"2.0","id":"1","method":"GetSystemInfo"}' | \
  wootc.exe serve
```

### Playwright E2E tests

The E2E harness uses the RPC interface for GUI testing:
- See `tests/gui/` for Playwright test configuration
- Tests drive the RPC through process handles, not raw stdin/stdout

### Integration testing

For integration tests:
1. Start `wootc.exe serve` in an elevated subprocess
2. Connect via stdin/stdout (or named pipe in Phase B)
3. Send method calls and observe responses
4. Verify state changes via `GetStatus` and other observers
5. Call `Shutdown` to cleanly exit

---

## Design Principles

1. **Stateful**: The server maintains install state across multiple method calls
2. **Single session**: One connection at a time; disconnect cancels in-flight work
3. **Atomic operations**: Each method completes atomically or fails cleanly
4. **Durable recovery**: Failed operations record state for later `GetRecoveryVerdict`
5. **No secrets in JSON**: Passwords and keys never appear in diagnostic logs

---

## Future Enhancements (Phase B / C)

- Peer authentication via Windows process handles and tokens
- Named pipe transport (more secure than stdio)
- Streaming progress notifications
- Cancellation tokens for fine-grained control
- Schema validation and versioning
- Full WinUI 3 native shell integration

See [winui-shell.md](winui-shell.md) for the complete vision.

---

## References

- Source code: `app/serve.go`, `app/serve_*.go`
- Tests: `app/serve_*_test.go`, `tests/gui/`
- Related docs: [winui-shell.md](winui-shell.md), [backend-contract.md](backend-contract.md)
- JSON-RPC spec: https://www.jsonrpc.org/specification
