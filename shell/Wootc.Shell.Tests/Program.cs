using Wootc.Shell.Core;
using Wootc.Shell.Engine;

static void Check(bool condition, string name) { if (!condition) throw new Exception(name); Console.WriteLine($"PASS {name}"); }
var brand = new Branding { ProductName = "Bluefin Installer", Name = "Bluefin" };
var connector = new FakeConnector();
await using var controller = new StartupController(brand, connector);
Check(controller.Brand.ProductName == "Bluefin Installer" && controller.CanRequestPermission, "local identity visible before UAC");
connector.Result = new(ConnectionOutcome.PermissionDeclined);
await controller.RequestPermissionAsync();
Check(controller.Connection == ConnectionState.PermissionDeclined && controller.CanRequestPermission && controller.Route == StartupRoute.Assessment, "UAC refusal retains assessment and retry");
var oldSession = connector.Requests.Single().SessionId;
connector.Result = new(ConnectionOutcome.Connected, new FakeSession(new(new InstallStatus { Existing = true }, null)));
await controller.RequestPermissionAsync();
Check(controller.Route == StartupRoute.Manage && controller.Connection == ConnectionState.Ready, "observed existing installation selects management");
Check(connector.Requests.Last().SessionId != oldSession, "retry uses a fresh session identity");
await controller.RequestPermissionAsync();
Check(connector.Requests.Count == 2, "ready connection does not prompt twice");
Check(StartupController.SelectRoute(new(new InstallStatus { Running = true }, new RecoveryVerdict { Verdict = "failed" })) == StartupRoute.Progress, "active work takes priority over past failure");
foreach (var verdict in new[] { "failed", "interrupted", "one-shot-never-booted" })
    Check(StartupController.SelectRoute(new(new InstallStatus(), new RecoveryVerdict { Verdict = verdict })) == StartupRoute.Recovery, $"observed {verdict} selects recovery");
Check(StartupController.SelectRoute(new(new InstallStatus { Done = true }, null)) == StartupRoute.Assessment, "done alone does not infer existing installation");
var rejected = false;
try { StartupController.SelectRoute(new(new InstallStatus(), new RecoveryVerdict { Verdict = "future-value" })); } catch (InvalidDataException) { rejected = true; }
Check(rejected, "unknown verdict refuses a guessed startup route");
var badSession = new FakeSession(new(new InstallStatus(), new RecoveryVerdict { Verdict = "future-value" }));
await using var incompatible = new StartupController(brand, new FakeConnector { Result = new(ConnectionOutcome.Connected, badSession) });
await incompatible.RequestPermissionAsync();
Check(incompatible.Connection == ConnectionState.Unavailable && incompatible.CanRequestPermission && badSession.Disposed, "invalid startup disconnects and leaves retry visible");

sealed class FakeConnector : IEngineConnector
{
    public ConnectionAttempt Result { get; set; } = new(ConnectionOutcome.Unavailable);
    public List<ConnectRequest> Requests { get; } = [];
    public Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken cancellationToken) { Requests.Add(request); return Task.FromResult(Result); }
}
sealed class FakeSession(StartupSnapshot snapshot) : IEngineSession
{
    public bool Disposed { get; private set; }
    public Task<StartupSnapshot> ReadStartupAsync(CancellationToken cancellationToken) => Task.FromResult(snapshot);
    public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
}
