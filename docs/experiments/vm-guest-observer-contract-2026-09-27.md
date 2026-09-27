# VM guest observation draft — 2026-09-27

Source only. No guest service is installed. No VM is started.

```text
Current source:
  payload/vm-observer/boot_probe.py
  tests/unit/test_vm_guest_probe.py
  existing reviewed tests/e2e/phase3_ancestry.py dependency (not staged)

Request schema 1 (exact fields):
  schemaVersion=1
  runId, installId                 ASCII [A-Za-z0-9._-], 1..128
  diskId                          canonical lowercase GPT UUID
  sessionId, requestId            32 lowercase hex
  serviceSha256, ancestrySha256   authenticated builder source hashes
  username                        selected configured ordinary account
  action                          observe-boot-session only

Response:
  request identity copied exactly
  status=observed
  bootId                          successful canonical kernel boot ID
  kernelRelease                   current successful uname release
  ordinarySession                 loginctl fixed properties plus measured
                                  /proc leader UID and start ticks
  root                            measured unique GPT whole target, actual
                                  root/block/projection/Btrfs graph
  desktopQualified=false
  editorQualified=false

Refusal:
  unknown/missing/duplicate fields, JSON depth>32, nonfinite values;
  message>256KiB, per-channel identity change or replay;
  UID0/system/remote/TTY/nonactive/ambiguous ordinary session;
  failed command even with plausible stdout, root outside selected disk;
  unresolved/unknown block/projection/member graph;
  boot/session/leader-start change during successful observation.
  No failed observation writes a complete successful response.

Bounds:
  128 requests per channel; fixed action, no shell/argv/file path/write API.
  idle framing30s; partial frame3s; reply2s/nonblocking;
  observation8s; each fixed read-only command<=2s;
  stdout/stderr incrementally capped256KiB each;
  fresh child process group cancelled before reap; no reused-PID kill.
  Retained capture budget remains the separate reviewed QMP8files/32MiB.

Transport draft source (NOT enabled or runtime-qualified):
  QMP retains sole engine stdin/stdout ownership.
  Windows QEMU dedicated chardev pipe + virtserialport
  org.wootc.observation.1; cryptographic ephemeral pipe/session name.
  Engine connects only to that owned QEMU pipe; Windows
  GetNamedPipeServerProcessId must match the live owned process PID.
  Process handle/start identity and App current-session pointer must match
  before/after every exchange; requestId fresh and reply bound exactly.
  No TCP listener, arbitrary QMP, guest exec or file-write API.
  Cancellation closes channel and invalidates observations.
  Host parser checks reply shape; independent graph acceptance is still owed.
  Same disk after a clean stop/restart still needs a new observed boot ID.
  Fixed authenticated personalization must stage interpreter/service and
  reviewed ancestry bytes; availability must be positively checked.
  Proposed unit: /usr/bin/python3 -I -B
    /usr/libexec/wootc-observer/boot_probe.py
  Explicit module path: /usr/libexec/wootc-observer/wootc_ancestry.py
  UID0/protected canonical ancestry for module/tool files; no PYTHONPATH
  or user-writable cwd/tool lookup. Fixed /usr/bin and /usr/sbin tools.
  Missing interpreter/module/tool/source hash refuses before observation.

Next GUI semantic source (NOT implemented or enabled):
  Read-only ordinary-user accessibility observer in the actual selected
  graphical session, with process UID/start/executable identity checks.
  Prove real GNOME shell and supported editor availability/accessibility.
  QMP input uses current accessible selectors, not blind key assumptions.
  Saved state requires actual editor document/path/dirty=false plus exact
  current file bytes and measured home/data backing on selected target.
  Close/reopen requires actual window disappearance/new editor observation.
  Engine clean stop/restart requires changed current kernel boot identity,
  same installed target/data identity, and actual reopened GUI document.
  Missing dependency/accessibility/session/editor/source remains unknown.
  The current producer does not supply any of these editor assertions.

Acceptance still owed:
  Actual Windows/WHPX runtime, selected target Linux ordinary desktop,
  real editor save/close/reopen, clean stop/restart, and persisted reopen.
```

QEMU documents a duplex pipe backend on Windows. The proposed engine client will check the server process through the Windows API before using it. These links support the transport plan; they do not prove a current runtime connection. [QEMU backend](https://www.qemu.org/docs/master/system/qemu-manpage.html), [Windows pipe identity](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getnamedpipeserverprocessid).
