using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

public enum StartupRoute { Assessment, Progress, Manage, Recovery, Interrupted }
public enum ConnectionState { Offline, RequestingPermission, Ready, PermissionDeclined, Unavailable, DisconnectPending }
public enum ConnectionOutcome { Connected, PermissionDeclined, Incompatible, Unavailable }
public sealed record StartupSnapshot(InstallStatus Status, RecoveryVerdict? Recovery, LifecycleState? LastRun = null, InstallRecoverySummary? InstallRecovery = null);
// Install selects a separate install-purpose engine session. The assessment
// connection never becomes one; a new elevation and session are required.
public sealed record ConnectRequest(string SessionId, bool Install = false);
public sealed record ConnectionAttempt(ConnectionOutcome Outcome, IEngineSession? Session = null, string? Reason = null);

// Implementations must authenticate the actual operating-system peer before
// exposing a session. Handshake messages cannot establish peer identity.
public interface IEngineConnector
{
    Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken cancellationToken);
}
public interface IEngineSession : IAsyncDisposable
{
    Task<StartupSnapshot> ReadStartupAsync(CancellationToken cancellationToken);
}

// An install-purpose session: one plan, one confirmation. The engine grants
// the intent; the shell never infers it from a complete form.
public interface IInstallEngineSession : IEngineSession
{
    Task<NativeInstallGrant> PrepareInstallAsync(InstallConfig plan, CancellationToken cancellationToken);
    Task ConfirmInstallAsync(NativeInstallGrant grant, CancellationToken cancellationToken);
    // install:progress notifications of this session, validated, in order.
    event Action<ProgressEvent>? ProgressReceived;
    Task<InstallStatus> GetInstallStatusAsync(CancellationToken cancellationToken);
    Task CancelInstallAsync(CancellationToken cancellationToken);
    // The engine allows it only after this session's install finished.
    Task RebootAsync(CancellationToken cancellationToken);
}

public interface IConfigurationEngineSession : IEngineSession
{
    Task<NativeConfigurationSnapshot> ReadConfigurationAsync(CancellationToken cancellationToken, Action<long>? requestFlushed = null);
}

public sealed class StartupController : IAsyncDisposable
{
    private readonly IEngineConnector connector;
    private readonly SemaphoreSlim connectionGate = new(1, 1);
    private IEngineSession? session;
    public Branding Brand { get; }
    public ConnectionState Connection { get; private set; } = ConnectionState.Offline;
    public StartupRoute Route { get; private set; } = StartupRoute.Assessment;
    public string? Problem { get; private set; }
    public StartupSnapshot? Snapshot { get; private set; }
    public bool CanRequestPermission => Connection is not ConnectionState.RequestingPermission and not ConnectionState.Ready and not ConnectionState.DisconnectPending;

    public StartupController(Branding brand, IEngineConnector connector)
    {
        if (string.IsNullOrWhiteSpace(brand.ProductName) || string.IsNullOrWhiteSpace(brand.Name))
            throw new ArgumentException("Local product and distribution identity are required", nameof(brand));
        Brand = brand;
        this.connector = connector;
    }

    public static StartupRoute SelectRoute(StartupSnapshot snapshot)
    {
        if (snapshot.Status.Running) return StartupRoute.Progress;
        string lifecycle = snapshot.LastRun?.State ?? "";
        if (lifecycle == "failed") return StartupRoute.Recovery;
        if (lifecycle is not ("" or "staged" or "armed" or "deploying" or "deployed" or "healthy"))
            throw new InvalidDataException("The engine returned an unsupported lifecycle state");
        string verdict = snapshot.Recovery?.Verdict ?? "";
        if (verdict is "failed" or "interrupted" or "one-shot-never-booted") return StartupRoute.Recovery;
        if (verdict is not ("" or "healthy" or "deployed"))
            throw new InvalidDataException("The engine returned an unsupported recovery verdict");
        // Same order as the legacy relaunch: a boot verdict first, then the
        // install journal's classification (#287).
        string install = snapshot.InstallRecovery?.Class ?? "none";
        if (install is "resumable" or "failed" or "needs-repair") return StartupRoute.Interrupted;
        if (install is not ("none" or "complete" or "in-progress"))
            throw new InvalidDataException("The engine returned an unsupported install recovery class");
        // This route offers management. It does not assert a verified Linux boot.
        if (snapshot.Status.Existing) return StartupRoute.Manage;
        return StartupRoute.Assessment;
    }

    public async Task RequestPermissionAsync(CancellationToken cancellationToken = default)
    {
        if (!await connectionGate.WaitAsync(0, cancellationToken)) return;
        try
        {
            if (Connection == ConnectionState.Ready) return;
            if (Connection == ConnectionState.DisconnectPending) await DisconnectAsync();
            Connection = ConnectionState.RequestingPermission;
            Problem = null;
            var request = new ConnectRequest(Guid.NewGuid().ToString("N"));
            var attempt = await connector.ConnectAsync(request, cancellationToken);
            if (attempt.Outcome != ConnectionOutcome.Connected)
            {
                if (attempt.Session is not null)
                {
                    session = attempt.Session;
                    await DisconnectAsync();
                }
                Connection = attempt.Outcome == ConnectionOutcome.PermissionDeclined
                    ? ConnectionState.PermissionDeclined : ConnectionState.Unavailable;
                Problem = attempt.Reason;
                return;
            }
            session = attempt.Session ?? throw new InvalidDataException("Authenticated engine session is missing");
            var observed = await session.ReadStartupAsync(cancellationToken);
            Route = SelectRoute(observed);
            Snapshot = observed;
            Connection = ConnectionState.Ready;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await DisconnectAsync();
        }
        catch (Exception error)
        {
            try
            {
                await DisconnectAsync();
                Connection = ConnectionState.Unavailable;
                Problem = error.Message;
            }
            catch (Exception cleanupError)
            {
                Problem = $"The engine has not completed disconnect: {cleanupError.Message}";
            }
        }
        finally { connectionGate.Release(); }
    }

    public async Task<NativeConfigurationSnapshot> ReadConfigurationAsync(CancellationToken cancellationToken = default, Action<long>? requestFlushed = null)
    {
        await connectionGate.WaitAsync(cancellationToken);
        try
        {
            if (Connection != ConnectionState.Ready || session is not IConfigurationEngineSession reader)
                throw new InvalidOperationException("Authenticated configuration session is unavailable");
            return await reader.ReadConfigurationAsync(cancellationToken, requestFlushed);
        }
        finally { connectionGate.Release(); }
    }

    private async Task DisconnectAsync()
    {
        if (session is not null)
        {
            Connection = ConnectionState.DisconnectPending;
            await session.DisposeAsync();
            session = null;
        }
        Connection = ConnectionState.Offline;
        Route = StartupRoute.Assessment;
        Snapshot = null;
    }
    public async ValueTask DisposeAsync()
    {
        await connectionGate.WaitAsync();
        try { await DisconnectAsync(); }
        finally { connectionGate.Release(); }
    }
}
