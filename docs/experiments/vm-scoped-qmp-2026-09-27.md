# Scoped QMP source controls — 2026-09-27

This source extends the managed engine from candidate `8e1c93e`.
It includes main `347f696`. It does not change the runtime or image.
The engine remains the sole owner of its inherited QMP pipes.
There is no new listener or public command endpoint.

| Boundary | Source behavior |
|---|---|
| Replies | Typed return/error; duplicate fields, absent return, null, unknown IDs and replay refuse |
| Calls | Ten-second maximum; context-aware write gate; short writes and timeout refuse |
| Session | Fresh nonce per process launch; persisted install/run/GPT identity remains separate |
| Display route | Internal engine method; exact session/directive identity; no raw QMP or guest command |
| Query | Successful typed running state and strict mouse inventory |
| Keys | Bounded enum; balanced press/release batch; exact successful acknowledgment |
| Capture | Engine selects private path; verifies PPM header, dimensions, pixels and SHA-256 |
| Retention | Actual inventory across launches; eight captures and 32 MiB maximum; exhaustion refuses before QMP |
| Cleanup | Only failed fresh capture directory; prior proof remains until explicit consumer release |
| Lifecycle | Display actions serialize with stop/force; explicit force remains possible during guest shutdown wait |
| Desktop | Always unqualified; process/QMP/framebuffer cannot establish editor or guest identity |

The API defines replies with types for status, mice and input events.
It defines PPM as the default capture format, with an empty acknowledgment on success.
[QEMU 8.2 QMP reference](https://qemu.readthedocs.io/en/v8.2.10/interop/qemu-qmp-ref.html#screendump-command).

The approved native control uses QEMU 8.2.2 with TCG and `-S`.
It uses 128 MiB, no attached disk, no network and no guest installation.
The actual status was `prelaunch`, with `running` false.
The engine verified an actual 640×480 PPM and rejected a failed capture command.
This proves the protocol component only. It does not prove execution of a guest CPU or desktop acceptance.

The child processes use inherited pipes to exercise the actual engine.
Their simulated status/editor context cannot qualify a real guest.
The old parser accepted a matching capability ID without a return field.
The control for the old source fails. The current control passes.
Controls also fail if I remove guards for replies, sessions, active state or pixels.

The internal route still needs an RPC adapter for tests. Review that adapter separately.
No channel exists for current guest semantics.
Real Windows/WHPX execution, ordinary-user GNOME identity, and editor save/close/reopen remain open.
The full persistence gate must use the same installed disk and firmware across a clean stop and restart.
