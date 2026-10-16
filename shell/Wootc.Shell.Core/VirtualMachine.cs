using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

public static class VMActions
{
    public const string InstallRuntime = "install-runtime";
    public const string Prepare = "prepare";
    public const string Boot = "boot";
    public const string Stop = "stop";
    public const string ForceStop = "force-stop";
}

// The versioned VM contract of an install-purpose session. The status is a
// projection without paths or process identities. Every action that changes
// the VM needs its own engine grant, used once. The session that starts a VM
// owns it: closing that session stops the VM.
public interface IVMEngineSession : IEngineSession
{
    Task<NativeVMStatus> ReadVMStatusAsync(CancellationToken cancellationToken);
    Task<NativeVMGrant> PrepareVMActionAsync(NativeVMPlan plan, CancellationToken cancellationToken);
    Task ConfirmVMActionAsync(NativeVMGrant grant, CancellationToken cancellationToken);
    // vm:progress notifications of this session, validated, in order.
    event Action<VMEvent>? VMProgressReceived;
}

public enum VMGateState { Idle, Opening, Open, Granting, Confirming, Refused }

// The Linux window through one install-purpose session. Unlike an install
// or a maintenance action, this session stays open: the engine that starts
// a VM owns it and stops it when the session closes. Each action that
// changes the VM still needs its own engine grant, used once.
public sealed class VMGate : IAsyncDisposable
{
    private static readonly System.Text.RegularExpressions.Regex LowerHex32 = new("^[0-9a-f]{32}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant);
    private readonly IEngineConnector connector;
    private readonly string brandId;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly object progressLock = new();
    private IVMEngineSession? session;
    private string sessionId = "";
    public VMGateState State { get; private set; } = VMGateState.Idle;
    public NativeVMStatus? Status { get; private set; }
    public VMEvent? Progress { get { lock (progressLock) return progress; } }
    private VMEvent? progress;
    // The last error: a refused grant, a failed action or an engine event.
    public string Reason { get; private set; } = "";
    public string? LastAction { get; private set; }
    // Raised on the engine reader thread; the view marshals it.
    public event Action? Changed;
    public bool IsOpen => session is not null && State is VMGateState.Open or VMGateState.Refused;

    public VMGate(IEngineConnector connector, string brandId)
    {
        if (string.IsNullOrWhiteSpace(brandId)) throw new ArgumentException("Brand identity is required", nameof(brandId));
        this.connector = connector;
        this.brandId = brandId;
    }

    public async Task OpenAsync(CancellationToken cancellationToken = default)
    {
        if (!await gate.WaitAsync(0, cancellationToken)) return;
        try
        {
            if (session is not null || State is not (VMGateState.Idle or VMGateState.Refused)) return;
            State = VMGateState.Opening;
            Reason = "";
            sessionId = Guid.NewGuid().ToString("N");
            var attempt = await connector.ConnectAsync(new ConnectRequest(sessionId, Install: true), cancellationToken);
            if (attempt.Outcome != ConnectionOutcome.Connected || attempt.Session is not IVMEngineSession opened)
            {
                if (attempt.Session is not null) await attempt.Session.DisposeAsync();
                State = VMGateState.Refused;
                Reason = attempt.Reason ?? "The install session is unavailable.";
                return;
            }
            session = opened;
            // Subscribed before the first read, so no event of this session is lost.
            opened.VMProgressReceived += OnProgress;
            Status = await opened.ReadVMStatusAsync(cancellationToken);
            State = VMGateState.Open;
        }
        catch (Exception error)
        {
            await CloseSessionAsync();
            State = VMGateState.Refused;
            Reason = error is OperationCanceledException && cancellationToken.IsCancellationRequested ? "" : error.Message;
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }

    private void OnProgress(VMEvent update)
    {
        lock (progressLock) progress = update;
        if (update.Stage is "error" or "needs_recovery" && update.Message.Length != 0) Reason = update.Message;
        Changed?.Invoke();
    }

    // Reads the engine's projection again, after an event that changes it.
    public async Task RefreshAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (session is null) return;
            try { Status = await session.ReadVMStatusAsync(cancellationToken); }
            catch (Exception error) { Reason = error.Message; }
        }
        finally { gate.Release(); }
        Changed?.Invoke();
    }

    // One action: the engine grants it, confirm decides (the click itself
    // for every action but force stop, as on the legacy screen), and the
    // intent is used once. The session stays open in every outcome.
    public async Task<bool> RunAsync(NativeVMPlan plan, Func<NativeVMGrant, Task<bool>> confirm, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(plan);
        await gate.WaitAsync(cancellationToken);
        bool ran = false;
        try
        {
            if (session is null || State is not (VMGateState.Open or VMGateState.Refused)) throw new InvalidOperationException("Read the Linux window status first");
            LastAction = plan.Action;
            Reason = "";
            State = VMGateState.Granting;
            NativeVMGrant grant;
            try { grant = await session.PrepareVMActionAsync(plan, cancellationToken); }
            catch (Exception error) { State = VMGateState.Refused; Reason = error.Message; return false; }
            string? mismatch = Mismatch(grant, plan);
            if (mismatch is not null) { State = VMGateState.Refused; Reason = mismatch; return false; }
            State = VMGateState.Open;
            if (!await confirm(grant)) return false;
            State = VMGateState.Confirming;
            if (plan.Action is VMActions.Prepare or VMActions.InstallRuntime)
                lock (progressLock) progress = null;
            try
            {
                await session.ConfirmVMActionAsync(grant, cancellationToken);
                ran = true;
                State = VMGateState.Open;
            }
            catch (Exception error) { State = VMGateState.Refused; Reason = error.Message; }
            try { Status = await session.ReadVMStatusAsync(cancellationToken); } catch (Exception error) { Reason = Reason.Length != 0 ? Reason : error.Message; }
            return ran;
        }
        finally { gate.Release(); Changed?.Invoke(); }
    }

    private string? Mismatch(NativeVMGrant grant, NativeVMPlan plan)
    {
        if (grant is null || grant.SchemaVersion != 1 || grant.Session != sessionId || grant.BrandId != brandId || !LowerHex32.IsMatch(grant.IntentId))
            return "The engine's grant does not belong to this session.";
        if (grant.Action != plan.Action || (plan.Action == VMActions.Prepare && (grant.ImageRef != plan.ImageRef || grant.Username != plan.Username)))
            return "The engine granted a different action from the one on screen.";
        return null;
    }

    private async Task CloseSessionAsync()
    {
        var current = session;
        session = null;
        if (current is null) return;
        current.VMProgressReceived -= OnProgress;
        await current.DisposeAsync();
    }

    // Closing the session stops a VM it started: the engine shuts it down.
    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();
        try { await CloseSessionAsync(); State = VMGateState.Idle; }
        finally { gate.Release(); }
    }
}

// The legacy Linux window words (app/frontend/src/screens/vmpreview.js,
// launchpad.js and control.js). VMTextTests compares them with those files.
public static class VMText
{
    public static string StartInWindow(Branding brand) => $"Start {brand.Name} in a window";
    public const string SetUpRuntime = "Set up Linux in a window";
    public const string ChooseVersion = "Choose a Linux version above";
    public const string EnterUsername = "Enter a valid Linux username below";
    public const string SetPassword = "Set your Linux password below";
    public const string PasswordsDiffer = "Passwords do not match";
    public const string BuilderStarting = "Preparing the builder…";
    public const string CheckingRelease = "Checking this release…";
    public const string PreparingTitle = "Preparing your Linux system…";
    public const string Working = "Working…";
    public const string InProgress = "Preparation is in progress.";
    public const string CancelSetup = "Cancel setup";
    public const string ErrorTitle = "Couldn't start the preview";
    public const string StartingTitle = "Linux is starting";
    public static string StartingBody(string? imageName, Branding brand) =>
        $"{(string.IsNullOrEmpty(imageName) ? brand.Name : imageName)} is starting in its own window. Sign in with your Linux username and password when the login screen appears. Your work stays on this disk. To close Linux safely, use Shut down Linux below. Native boot is not available yet.";
    public const string ShutDown = "Shut down Linux";
    public const string ForceStop = "Force stop…";
    public const string ForceStopConfirm = "Force stop Linux? Unsaved work may be lost. The disk will require recovery before restarting.";
    public const string StoppedTitle = "Linux is shut down. Your work is saved on the same disk.";
    public const string StartAgain = "Start Linux again";
    public const string TryTitle = "Try Linux in a window";
    public static string TryBody(Branding brand, string accelerator) =>
        $"Boot your installed {brand.Name} in a window using {(accelerator.Length != 0 ? accelerator : "hardware acceleration").Split(',')[0].ToUpperInvariant()}. Changes persist — it's the same system.";
    public const string BootInVM = "Boot in VM";

    // The legacy launch button's hint, in its order.
    public static string PrepareBlockedReason(string? imageRef, string username, string password, string confirmation) =>
        string.IsNullOrEmpty(imageRef) ? ChooseVersion
        : !System.Text.RegularExpressions.Regex.IsMatch(username, "^[a-z_][a-z0-9_-]{0,31}$") || username == "root" ? EnterUsername
        : password.Length == 0 ? SetPassword
        : password != confirmation ? PasswordsDiffer : "";
}

public sealed record VMView(IReadOnlyList<MaintenanceLine> Lines, IReadOnlyList<MaintenanceButton> Buttons, bool ShowProgress, double ProgressValue);

// What the Linux window panel shows for the session, its status and events.
public static class VMScreen
{
    public const string ReadStatus = "Read Linux window status";
    public const string RequestingPermission = "Requesting administrator permission";
    public const string Checking = "Checking this action with the engine";

    public static VMView For(VMGate? gate, Branding brand, string? imageName, string prepareBlocked)
    {
        var lines = new List<MaintenanceLine>();
        var buttons = new List<MaintenanceButton>();
        var state = gate?.State ?? VMGateState.Idle;
        if (gate is null || !gate.IsOpen && state is not (VMGateState.Granting or VMGateState.Confirming))
        {
            if (state == VMGateState.Opening) lines.Add(new("VMStatus", RequestingPermission));
            else if (state == VMGateState.Refused && gate!.Reason.Length != 0) lines.Add(new("VMStatus", gate.Reason));
            buttons.Add(new("ReadVMStatus", ReadStatus, state is VMGateState.Idle or VMGateState.Refused));
            return new(lines, buttons, false, 0);
        }
        bool idle = state is VMGateState.Open or VMGateState.Refused;
        var status = gate.Status;
        var progress = gate.Progress;
        string phase = status?.Phase ?? "absent";
        bool failed = progress?.Stage is "error" or "needs_recovery" || phase is "needs_recovery" or "failed";
        bool started = progress?.Stage == "started" || phase is "running" or "starting";
        bool preparing = !started && (progress is not null && progress.Stage is not ("stopped" or "runtime-ready") || phase == "preparing");
        double value = 0;
        if (failed && (gate.Reason.Length != 0 || status?.Error.Length > 0))
        {
            lines.Add(new("VMTitle", VMText.ErrorTitle));
            lines.Add(new("VMMessage", gate.Reason.Length != 0 ? gate.Reason : status!.Error));
        }
        else if (started)
        {
            lines.Add(new("VMTitle", VMText.StartingTitle));
            lines.Add(new("VMMessage", VMText.StartingBody(imageName, brand)));
            buttons.Add(new("ShutDownLinux", VMText.ShutDown, idle));
            buttons.Add(new("ForceStopLinux", VMText.ForceStop, idle));
        }
        else if (preparing)
        {
            lines.Add(new("VMTitle", VMText.PreparingTitle));
            string fallback = gate.LastAction == VMActions.InstallRuntime ? VMText.CheckingRelease : VMText.BuilderStarting;
            lines.Add(new("VMMessage", progress is null ? fallback : progress.Message.Length != 0 ? progress.Message : VMText.Working));
            lines.Add(new("VMInProgress", VMText.InProgress));
            if (progress?.Stage == "runtime-download") value = Math.Max(0, Math.Min(100, Math.Round(progress.Percent, MidpointRounding.AwayFromZero)));
            buttons.Add(new("CancelSetup", VMText.CancelSetup, idle));
        }
        else if (phase == "stopped")
        {
            lines.Add(new("VMTitle", VMText.StoppedTitle));
            buttons.Add(new("StartLinuxAgain", VMText.StartAgain, idle && status!.Launch.Available));
            if (!status!.Launch.Available && status.Launch.Reason.Length != 0) lines.Add(new("VMReason", status.Launch.Reason));
        }
        else if (phase == "ready")
        {
            lines.Add(new("VMTitle", VMText.TryTitle));
            lines.Add(new("VMMessage", status!.Launch.Available ? VMText.TryBody(brand, status.Launch.Accelerator) : status.Launch.Reason));
            buttons.Add(new("BootInVM", VMText.BootInVM, idle && status.Launch.Available));
        }
        else if (phase == "absent")
        {
            var prepare = status?.Prepare ?? new NativeVMCapability();
            if (prepare.Available)
            {
                buttons.Add(new("StartInWindow", VMText.StartInWindow(brand), idle && prepareBlocked.Length == 0));
                if (prepareBlocked.Length != 0) lines.Add(new("VMHint", prepareBlocked));
            }
            if (prepare.RuntimeNeeded) buttons.Add(new("SetUpRuntime", VMText.SetUpRuntime, idle));
            if (!prepare.Available && prepare.Reason.Length != 0) lines.Add(new("VMReason", prepare.Reason));
        }
        else if (status?.Error.Length > 0) lines.Add(new("VMReason", status.Error));
        if (state == VMGateState.Granting) lines.Add(new("VMStatus", Checking));
        else if (state == VMGateState.Refused && gate.Reason.Length != 0 && !failed) lines.Add(new("VMStatus", gate.Reason));
        return new(lines, buttons, preparing, value);
    }
}
