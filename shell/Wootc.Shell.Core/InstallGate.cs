using System.Text.RegularExpressions;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

public enum InstallGateState { Idle, Preparing, Granted, Refused, Confirming, Started, Failed, Cancelling, Cancelled, Finished, Restarting }

// Install is enabled only by an engine grant for the exact plan on screen.
// Each plan gets its own install-purpose session (a new elevation); a changed
// form discards the grant and that session. Confirming uses the grant's
// intent once: success or failure, a retry needs a new plan.
public sealed class InstallGate : IAsyncDisposable
{
    private static readonly Regex LowerHex32 = new("^[0-9a-f]{32}$", RegexOptions.CultureInvariant);
    private readonly IEngineConnector connector;
    private readonly string brandId;
    private readonly SemaphoreSlim gate = new(1, 1);
    private IInstallEngineSession? session;
    private string sessionId = "";
    private readonly object stateLock = new();
    private InstallGateState state = InstallGateState.Idle;
    public InstallGateState State { get { lock (stateLock) return state; } private set { lock (stateLock) state = value; } }
    // The progress of a confirmed install, fed by this session's events.
    public InstallProgress? Progress { get; private set; }
    // Raised on the engine reader thread; the view marshals it.
    public event Action? Changed;
    public string Reason { get; private set; } = "";
    public NativeInstallGrant? Grant { get; private set; }
    public bool CanInstall => State == InstallGateState.Granted && Grant is not null;

    public InstallGate(IEngineConnector connector, string brandId)
    {
        if (string.IsNullOrWhiteSpace(brandId)) throw new ArgumentException("Brand identity is required", nameof(brandId));
        this.connector = connector;
        this.brandId = brandId;
    }

    public async Task PrepareAsync(InstallConfig plan, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plan);
        if (!await gate.WaitAsync(0, cancellationToken)) return;
        try
        {
            if (State is not (InstallGateState.Idle or InstallGateState.Granted or InstallGateState.Refused or InstallGateState.Failed or InstallGateState.Cancelled)) return;
            await CloseSessionAsync();
            Progress = null;
            State = InstallGateState.Preparing;
            Reason = "";
            sessionId = Guid.NewGuid().ToString("N");
            var attempt = await connector.ConnectAsync(new ConnectRequest(sessionId, Install: true), cancellationToken);
            if (attempt.Outcome != ConnectionOutcome.Connected || attempt.Session is not IInstallEngineSession opened)
            {
                if (attempt.Session is not null) await attempt.Session.DisposeAsync();
                Refuse(attempt.Reason ?? "The install session is unavailable.");
                return;
            }
            session = opened;
            var grant = await opened.PrepareInstallAsync(plan, cancellationToken);
            string? mismatch = Mismatch(grant, plan);
            if (mismatch is not null) { await CloseSessionAsync(); Refuse(mismatch); return; }
            Grant = grant;
            State = InstallGateState.Granted;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            string? cleanup = await CloseSessionAfterFailureAsync();
            if (cleanup is null) State = InstallGateState.Idle;
            else Refuse(cleanup);
        }
        catch (Exception error)
        {
            // The plan check failed. Closing its session can fail too (an
            // engine still busy past its disconnect deadline); that must not
            // leave the gate in Preparing with no reason, which looks like a
            // check still running and disables the form for good.
            string reason = error is OperationCanceledException
                ? "The engine did not finish checking this plan in time."
                : error.Message;
            string? cleanup = await CloseSessionAfterFailureAsync();
            Refuse(cleanup is null ? reason : $"{reason} {cleanup}");
        }
        finally
        {
            gate.Release();
            // Every outcome reaches the view, including the early returns.
            Changed?.Invoke();
        }
    }

    // Closes the session of a failed check. Returns why cleanup failed, or null.
    private async Task<string?> CloseSessionAfterFailureAsync()
    {
        try { await CloseSessionAsync(); return null; }
        catch (Exception error) { return string.IsNullOrWhiteSpace(error.Message) ? "The engine session did not close." : error.Message; }
    }

    // Confirming sends only the grant's intent. The engine runs the plan it
    // granted, never a plan supplied with the confirmation. Progress is
    // subscribed first, so no early event of the install is lost.
    public async Task ConfirmAsync(IEnumerable<StepDefinition> steps, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (!CanInstall || session is null) throw new InvalidOperationException("No granted install plan");
            var progress = new InstallProgress(steps);
            Progress = progress;
            State = InstallGateState.Confirming;
            session.ProgressReceived += OnProgress;
            try
            {
                await session.ConfirmInstallAsync(Grant!, cancellationToken);
                lock (stateLock) { if (state == InstallGateState.Confirming) state = InstallGateState.Started; }
            }
            catch (Exception error)
            {
                session.ProgressReceived -= OnProgress;
                Grant = null;
                Progress = null;
                await CloseSessionAsync();
                State = InstallGateState.Failed;
                Reason = error.Message;
            }
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }

    private void OnProgress(ProgressEvent update)
    {
        lock (stateLock)
        {
            if (Progress is null || state is not (InstallGateState.Confirming or InstallGateState.Started or InstallGateState.Cancelling)) return;
            Progress.Apply(update);
            if (Progress.Done && state != InstallGateState.Cancelling) state = InstallGateState.Finished;
            else if (Progress.Error is { } error && state != InstallGateState.Cancelling) { state = InstallGateState.Failed; Reason = error; }
        }
        Changed?.Invoke();
    }

    // Cancel goes through the install session; the session stays open until
    // the engine reports the install stopped, because closing it is itself a
    // cancellation request that must not race the first one.
    public async Task CancelAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (State != InstallGateState.Started || session is null) return;
            State = InstallGateState.Cancelling;
            Changed?.Invoke();
            try
            {
                await session.CancelInstallAsync(cancellationToken);
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                deadline.CancelAfter(TimeSpan.FromMinutes(5));
                while ((await session.GetInstallStatusAsync(deadline.Token)).Running) await Task.Delay(500, deadline.Token);
                session.ProgressReceived -= OnProgress;
                await CloseSessionAsync();
                State = InstallGateState.Cancelled;
            }
            catch (Exception error)
            {
                State = InstallGateState.Failed;
                Reason = error.Message;
            }
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }

    // Only a finished install of this session can request the restart.
    public async Task RebootAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (State != InstallGateState.Finished || session is null) throw new InvalidOperationException("No finished installation");
            State = InstallGateState.Restarting;
            try { await session.RebootAsync(cancellationToken); }
            catch (Exception error) { State = InstallGateState.Finished; Reason = error.Message; throw; }
        }
        finally { gate.Release(); }
    }

    // A form change discards the grant and its session. A started install
    // keeps its session: closing it would cancel the running install.
    public async Task InvalidateAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (State is not (InstallGateState.Preparing or InstallGateState.Granted or InstallGateState.Refused)) return;
            await CloseSessionAsync();
            State = InstallGateState.Idle;
            Reason = "";
        }
        finally { gate.Release(); }
    }

    private string? Mismatch(NativeInstallGrant grant, InstallConfig plan)
    {
        string encryption = plan.Encryption.Length == 0 ? "none" : plan.Encryption;
        if (grant is null || grant.SchemaVersion != 1 || grant.Session != sessionId || grant.BrandId != brandId || !LowerHex32.IsMatch(grant.IntentId))
            return "The engine's install grant does not belong to this session.";
        if (grant.ImageRef != plan.ImageRef || grant.StorageDrive != plan.StorageDrive || grant.DiskSizeGB != plan.DiskSizeGB || grant.Encryption != encryption)
            return "The engine granted a different plan from the one on screen.";
        return null;
    }

    private void Refuse(string reason)
    {
        Grant = null;
        State = InstallGateState.Refused;
        Reason = string.IsNullOrWhiteSpace(reason) ? "The engine refused this plan." : reason;
    }

    private async Task CloseSessionAsync()
    {
        Grant = null;
        var current = session;
        session = null;
        if (current is not null) await current.DisposeAsync();
    }

    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();
        try { await CloseSessionAsync(); }
        finally { gate.Release(); }
    }
}
