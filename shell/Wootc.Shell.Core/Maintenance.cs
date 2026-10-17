using System.Text.RegularExpressions;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

public static class MaintenanceActions
{
    public const string Uninstall = "uninstall";
    public const string RepairBoot = "repair-boot";
    public const string RestoreWindowsBoot = "restore-windows-boot";
    public const string TryAgain = "try-again";
    public const string BootLinux = "boot-linux";
}

// The Manage and Recovery actions of an install-purpose session: two reads,
// then one plan and one confirmation, as for an install (#623).
public interface IMaintenanceEngineSession : IEngineSession
{
    Task<UninstallInfo> ReadUninstallInfoAsync(CancellationToken cancellationToken);
    // Saves an evidence bundle; changes no boot entry.
    Task<BootRepairReport> InspectBootAsync(CancellationToken cancellationToken);
    Task<NativeMaintenanceGrant> PrepareMaintenanceAsync(NativeMaintenancePlan plan, CancellationToken cancellationToken);
    Task ConfirmMaintenanceAsync(NativeMaintenanceGrant grant, CancellationToken cancellationToken);
}

public enum MaintenanceGateState { Idle, Opening, Observed, Preparing, Granted, Confirming, Completed, Refused, Failed }

// A maintenance action is enabled only by an engine grant for the exact plan
// on screen. Each plan gets its own install-purpose session: declining,
// a refusal or a finished action closes it, and a next action needs a new
// session (a new elevation), never a reused intent.
public sealed class MaintenanceGate : IAsyncDisposable
{
    private static readonly Regex LowerHex32 = new("^[0-9a-f]{32}$", RegexOptions.CultureInvariant);
    private readonly IEngineConnector connector;
    private readonly string brandId;
    private readonly SemaphoreSlim gate = new(1, 1);
    private IMaintenanceEngineSession? session;
    private string sessionId = "";
    private NativeMaintenancePlan? plan;
    public MaintenanceGateState State { get; private set; } = MaintenanceGateState.Idle;
    public UninstallInfo? Info { get; private set; }
    public BootRepairReport? Boot { get; private set; }
    public NativeMaintenanceGrant? Grant { get; private set; }
    public string? CompletedAction { get; private set; }
    // The action of the last confirmation, finished or failed.
    public string? LastAction { get; private set; }
    public string Reason { get; private set; } = "";
    public bool CanConfirm => State == MaintenanceGateState.Granted && Grant is not null;

    public MaintenanceGate(IEngineConnector connector, string brandId)
    {
        if (string.IsNullOrWhiteSpace(brandId)) throw new ArgumentException("Brand identity is required", nameof(brandId));
        this.connector = connector;
        this.brandId = brandId;
    }

    // Opens a session and reads where the installation lives and the boot check.
    public async Task OpenAsync(CancellationToken cancellationToken = default)
    {
        if (!await gate.WaitAsync(0, cancellationToken)) return;
        try
        {
            if (State is not (MaintenanceGateState.Idle or MaintenanceGateState.Refused or MaintenanceGateState.Failed or MaintenanceGateState.Completed)) return;
            await CloseSessionAsync();
            State = MaintenanceGateState.Opening;
            Reason = "";
            CompletedAction = null;
            sessionId = Guid.NewGuid().ToString("N");
            var attempt = await connector.ConnectAsync(new ConnectRequest(sessionId, Install: true), cancellationToken);
            if (attempt.Outcome != ConnectionOutcome.Connected || attempt.Session is not IMaintenanceEngineSession opened)
            {
                if (attempt.Session is not null) await attempt.Session.DisposeAsync();
                Refuse(attempt.Reason ?? "The install session is unavailable.");
                return;
            }
            session = opened;
            Info = await opened.ReadUninstallInfoAsync(cancellationToken);
            Boot = await opened.InspectBootAsync(cancellationToken);
            State = MaintenanceGateState.Observed;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await CloseSessionAsync();
            State = MaintenanceGateState.Idle;
        }
        catch (Exception error)
        {
            await CloseSessionAsync();
            Refuse(error.Message);
        }
        finally { gate.Release(); }
    }

    public async Task PrepareAsync(NativeMaintenancePlan chosen, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(chosen);
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (State != MaintenanceGateState.Observed || session is null) throw new InvalidOperationException("Read the installation before choosing an action");
            State = MaintenanceGateState.Preparing;
            plan = new NativeMaintenancePlan { Action = chosen.Action, DeleteRootDisk = chosen.DeleteRootDisk, RemovePartition = chosen.RemovePartition };
            var grant = await session.PrepareMaintenanceAsync(plan, cancellationToken);
            string? mismatch = Mismatch(grant, plan);
            if (mismatch is not null) { await CloseSessionAsync(); Refuse(mismatch); return; }
            Grant = grant;
            State = MaintenanceGateState.Granted;
        }
        catch (Exception error) when (error is not InvalidOperationException)
        {
            await CloseSessionAsync();
            Refuse(error.Message);
        }
        finally { gate.Release(); }
    }

    // Declining the confirmation discards the grant with its session.
    public async Task DeclineAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (State != MaintenanceGateState.Granted) return;
            await CloseSessionAsync();
            State = MaintenanceGateState.Idle;
        }
        finally { gate.Release(); }
    }

    // Sends only the grant's intent; the engine runs the plan it granted. A
    // boot action reads the boot check again, so the screen shows the result.
    public async Task ConfirmAsync(CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken);
        try
        {
            if (!CanConfirm || session is null) throw new InvalidOperationException("No granted maintenance plan");
            var granted = Grant!;
            LastAction = granted.Action;
            State = MaintenanceGateState.Confirming;
            try
            {
                await session.ConfirmMaintenanceAsync(granted, cancellationToken);
                CompletedAction = granted.Action;
                State = MaintenanceGateState.Completed;
            }
            catch (Exception error)
            {
                State = MaintenanceGateState.Failed;
                Reason = error.Message;
            }
            if (granted.Action is MaintenanceActions.RepairBoot or MaintenanceActions.RestoreWindowsBoot)
            {
                try { Boot = await session.InspectBootAsync(cancellationToken); }
                catch (Exception error) { Boot = new BootRepairReport { BootState = "unknown", Refusals = [MaintenanceText.BootCheckFailed(error.Message)] }; }
            }
            await CloseSessionAsync();
        }
        finally { gate.Release(); }
    }

    private string? Mismatch(NativeMaintenanceGrant grant, NativeMaintenancePlan chosen)
    {
        if (grant is null || grant.SchemaVersion != 1 || grant.Session != sessionId || grant.BrandId != brandId || !LowerHex32.IsMatch(grant.IntentId))
            return "The engine's grant does not belong to this session.";
        if (grant.Action != chosen.Action || grant.DeleteRootDisk != chosen.DeleteRootDisk || grant.RemovePartition != chosen.RemovePartition)
            return "The engine granted a different action from the one on screen.";
        return null;
    }

    private void Refuse(string reason)
    {
        Grant = null;
        State = MaintenanceGateState.Refused;
        Reason = string.IsNullOrWhiteSpace(reason) ? "The engine refused this action." : reason;
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

// The legacy Manage and Recovery screens' own words
// (app/frontend/src/screens/control.js and recovery.js), HTML removed.
// MaintenanceTextTests compares every line with those files.
public static class MaintenanceText
{
    private static string Round(double value) => Math.Round(value, MidpointRounding.AwayFromZero).ToString(System.Globalization.CultureInfo.InvariantCulture);

    // Manage (control.js)
    public static string ManageTitle(Branding brand) => $"Manage {brand.Name}";
    public static string ManageSubtitle(Branding brand) => $"An existing {brand.Name} installation was found on this PC.";
    public static string FailedAttempt(string? stepLabel) =>
        $"Your last install attempt didn't finish (stopped at \"{(string.IsNullOrEmpty(stepLabel) ? "an early step" : stepLabel)}\"). " +
        "Nothing outside the installation folder was changed and no Linux boot is armed. " +
        "Choose Reinstall below to try again, or Uninstall to clean everything up.";
    public const string OrphanedTitle = "Leftover boot files found";
    public const string OrphanedBody = "The Linux disk file is gone, but a startup entry and boot files remain. Uninstall below removes them — Windows is unaffected either way.";
    public static string DiskLine(UninstallInfo info) =>
        (info.DiskPath.Length != 0 ? info.DiskPath : "C:\\wootc\\disks\\root.disk") + (info.DiskSizeGB != 0 ? $" ({Round(info.DiskSizeGB)} GB)" : "");
    public static string DiskBody(Branding brand) => $"Your {brand.Name} installation lives here. Removing it leaves Windows completely intact.";
    public static string InstalledTitle(Branding brand) => $"{brand.Name} is installed";
    public const string InstalledBody = "Restart to boot into it once. Windows stays your default — from Linux, the boot menu lists Windows too.";
    public static string RestartInto(Branding brand) => $"Restart into {brand.Name} →";
    public static string RestartFailed(Branding brand, string error) => $"Could not arm the {brand.Name} boot: " + error;
    public const string DeleteData = "Also delete my Linux data";
    public const string DeleteDataDetail = "Removes root.disk. Your Linux files, and the sealed copy of a BitLocker recovery key, are permanently deleted. Leave unchecked to keep them for later.";
    public static bool OffersPartition(UninstallInfo info) => info.OnDedicatedVol && info.ReclaimGB != 0;
    private static string Label(string? label) => string.IsNullOrEmpty(label) ? "wootc-data" : label;
    public static string GiveBack(UninstallInfo info) => $"Give the {Round(info.ReclaimGB)} GB back to Windows";
    public static string GiveBackDetail(UninstallInfo info) => $"Removes the {Label(info.VolumeLabel)} drive ({info.StorageDrive}:) and extends C: into the freed space.";
    public const string Reinstall = "Reinstall";
    public static string Uninstall(Branding brand) => $"Uninstall {brand.Name}";
    public const string Close = "Close";

    // The uninstall confirmation, from the engine's grant: what it observed,
    // not what the form assumed.
    public static string ConfirmUninstallHead(Branding brand) => $"Remove {brand.Name}?\n\nThis removes the boot entry, the ESP files, and the deployer files.";
    public const string ConfirmDeleteData = "\n\n⚠ Your Linux data (root.disk) will be permanently deleted.";
    public const string ConfirmKeepData = "\n\nYour Linux data (root.disk) will be kept.";
    public static string ConfirmRemovePartition(NativeMaintenanceGrant grant) =>
        $"\n⚠ The {Label(grant.VolumeLabel)} drive ({(grant.StorageDrive.Length != 0 ? grant.StorageDrive : "D")}:) will be removed and its space returned to C:.";
    public static string ConfirmUninstall(Branding brand, NativeMaintenanceGrant grant) =>
        ConfirmUninstallHead(brand) + (grant.DeleteRootDisk ? ConfirmDeleteData : ConfirmKeepData) + (grant.RemovePartition ? ConfirmRemovePartition(grant) : "");
    public static string Removed(Branding brand) => $"{brand.Name} has been removed. Windows is unchanged.";
    public static string UninstallProblem(string error) => "Uninstall hit a problem: " + error;

    // Recovery (recovery.js)
    public static string RecoveryTitle(RecoveryVerdict? verdict, Branding brand) =>
        string.IsNullOrEmpty(verdict?.Title) ? $"Could not finish setting up {brand.Name} this time" : verdict.Title;
    public static string RecoveryMessage(RecoveryVerdict? verdict) =>
        string.IsNullOrEmpty(verdict?.Message) ? "Windows restarted before the installation could complete." : verdict.Message;
    public const string Safe = "Your Windows and all of your files are safe and untouched.";
    public const string SafeDetail = "Windows remains your default system. No personal files or existing operating systems were changed.";
    public static string Stage(string phase) => "Stage: " + phase;
    public const string LogDetails = "View recent log details";
    public static string LogTail(RecoveryVerdict verdict) => string.Join("\n", (verdict.LogTail ?? []).TakeLast(10));
    public const string NoDetails = "Choose an option below to proceed.";
    public const string CheckingBoot = "Checking the boot configuration…";
    public static string BootState(string? state, Branding brand) => state switch
    {
        "windows-only" => $"Windows starts normally. {brand.ProductName} is not in the boot order.",
        "one-shot-armed" => "The next restart (only) goes to the Linux installer.",
        "wootc-default" => $"A startup entry from {brand.ProductName} is ahead of Windows in the boot order.",
        "wootc-listed" => $"Windows starts first; a startup entry from {brand.ProductName} is still in the boot order.",
        "foreign-next" => $"The next restart goes to an entry {brand.ProductName} does not own.",
        _ => "The boot configuration could not be read.",
    };
    // The boot check's lines, in the legacy order.
    public static IReadOnlyList<string> BootLines(BootRepairReport report)
    {
        var lines = new List<string>(report.Findings ?? []);
        lines.AddRange((report.Refusals ?? []).Select(NotOffered));
        if (!string.IsNullOrEmpty(report.BundlePath)) lines.Add(DetailsSaved(report.BundlePath));
        return lines;
    }
    public static string NotOffered(string text) => "Not offered: " + text;
    public static string DetailsSaved(string path) => "Details saved to " + path;
    public static string BootCheckFailed(string error) => "boot check failed: " + error;
    public static string Remove(Branding brand) => $"Remove {brand.Name}";
    public const string KeepWindows = "Keep Windows only";
    public const string RepairBoot = "Repair boot";
    public const string TryAgain = "Try again →";
    public static string ConfirmRemove(Branding brand) => $"Remove {brand.Name} files and restore the boot configuration?";
    public static string RemovalError(string error) => "Removal encountered an error: " + error;
    public const string WindowsRestored = "Windows will start normally. Your setup files are kept, so you can try again later.";
    public static string RestoreFailed(string error) => "Windows boot was not restored: " + error;
    public const string Repaired = "Boot configuration repaired and checked. Your computer will restart to try again.";
    public static string RepairFailed(string error) => "Repair boot hit a problem: " + error;
    public static string TryAgainFailed(string error) => "Try again hit a problem: " + error;

    // The engine refuses what this offers too; the screen only mirrors it.
    public static bool CanRestoreWindows(BootRepairReport? report) => report?.CanRestoreWindows == true;
    public static bool CanRepairBoot(BootRepairReport? report) => report?.CanRepairBoot == true;

    // What a finished or failed action says, by the screen it came from.
    public static string Outcome(string action, bool recovery, Branding brand, string? error) => (action, error) switch
    {
        (MaintenanceActions.Uninstall, null) => Removed(brand),
        (MaintenanceActions.Uninstall, _) => recovery ? RemovalError(error) : UninstallProblem(error),
        (MaintenanceActions.RestoreWindowsBoot, null) => WindowsRestored,
        (MaintenanceActions.RestoreWindowsBoot, _) => RestoreFailed(error),
        (MaintenanceActions.RepairBoot, null) => Repaired,
        (MaintenanceActions.RepairBoot, _) => RepairFailed(error),
        (MaintenanceActions.TryAgain, null) => "",
        (MaintenanceActions.TryAgain, _) => TryAgainFailed(error),
        (MaintenanceActions.BootLinux, null) => "",
        (MaintenanceActions.BootLinux, _) => RestartFailed(brand, error),
        _ => error ?? "",
    };

    // The question asked before a granted plan runs, or null when the
    // legacy screen ran the action on the click itself (Keep Windows only,
    // Repair boot, Try again, Restart into). The engine's grant and its
    // single-use intent still sit between that click and the action.
    public static string? Confirmation(NativeMaintenanceGrant grant, bool recovery, Branding brand) =>
        grant.Action == MaintenanceActions.Uninstall ? (recovery ? ConfirmRemove(brand) : ConfirmUninstall(brand, grant)) : null;
}

public sealed record MaintenanceLine(string Id, string Text);
public sealed record MaintenanceButton(string Id, string Label, bool Enabled);
public sealed record MaintenanceView(IReadOnlyList<MaintenanceLine> Lines, IReadOnlyList<MaintenanceButton> Buttons, bool OfferDeleteData, bool OfferPartition, string Status);

// What the Manage and Recovery screens show for a route, the startup
// snapshot and the maintenance session. The legacy screens read the
// installation at launch; here every action needs the install session, so
// the details appear once that session has read them, and actions are
// enabled only while it is open.
public static class MaintenanceScreen
{
    public const string ReadDetails = "Read installation details";
    public const string CheckingAction = "Checking this action with the engine";
    public const string RequestingPermission = "Requesting administrator permission";
    public const string Working = "The engine is carrying out this action. Keep this window open.";

    public static MaintenanceView? For(StartupRoute route, StartupSnapshot? snapshot, MaintenanceGate? gate, Branding brand, Func<string, string> stepLabel)
    {
        if (route is not (StartupRoute.Manage or StartupRoute.Recovery) || snapshot is null) return null;
        var state = gate?.State ?? MaintenanceGateState.Idle;
        bool open = state == MaintenanceGateState.Observed;
        var info = open || state is MaintenanceGateState.Completed or MaintenanceGateState.Failed ? gate!.Info : null;
        var boot = gate?.Boot;
        var lines = new List<MaintenanceLine>();
        var buttons = new List<MaintenanceButton>();
        bool readable = state is MaintenanceGateState.Idle or MaintenanceGateState.Refused or MaintenanceGateState.Failed or MaintenanceGateState.Completed;
        bool offerDelete = false, offerPartition = false;
        if (route == StartupRoute.Manage)
        {
            lines.Add(new("ManageTitle", MaintenanceText.ManageTitle(brand)));
            lines.Add(new("ManageSubtitle", MaintenanceText.ManageSubtitle(brand)));
            if (snapshot.LastRun?.State == "failed")
            {
                string id = !string.IsNullOrEmpty(snapshot.LastRun.PhaseId) ? snapshot.LastRun.PhaseId : snapshot.LastRun.Phase ?? "";
                lines.Add(new("ManageFailedAttempt", MaintenanceText.FailedAttempt(id.Length == 0 ? "" : stepLabel(id))));
            }
            if (info is not null)
            {
                if (info.Orphaned)
                {
                    lines.Add(new("ManageCardTitle", MaintenanceText.OrphanedTitle));
                    lines.Add(new("ManageCardBody", MaintenanceText.OrphanedBody));
                }
                else
                {
                    lines.Add(new("ManageCardTitle", MaintenanceText.DiskLine(info)));
                    lines.Add(new("ManageCardBody", MaintenanceText.DiskBody(brand)));
                }
                if (info.Deployed)
                {
                    lines.Add(new("ManageInstalledTitle", MaintenanceText.InstalledTitle(brand)));
                    lines.Add(new("ManageInstalledBody", MaintenanceText.InstalledBody));
                    buttons.Add(new("RestartIntoLinux", MaintenanceText.RestartInto(brand), open));
                }
                offerDelete = open;
                offerPartition = open && MaintenanceText.OffersPartition(info);
                if (!string.IsNullOrEmpty(info.PartitionRemovalReason)) lines.Add(new("ManagePartitionReason", info.PartitionRemovalReason));
            }
            buttons.Add(new("ReadInstallation", ReadDetails, readable));
            buttons.Add(new("Reinstall", MaintenanceText.Reinstall, state is not (MaintenanceGateState.Preparing or MaintenanceGateState.Confirming)));
            buttons.Add(new("UninstallLinux", MaintenanceText.Uninstall(brand), open));
            buttons.Add(new("CloseWindow", MaintenanceText.Close, state != MaintenanceGateState.Confirming));
        }
        else
        {
            var verdict = snapshot.Recovery;
            lines.Add(new("RecoveryTitle", MaintenanceText.RecoveryTitle(verdict, brand)));
            lines.Add(new("RecoveryMessage", MaintenanceText.RecoveryMessage(verdict)));
            lines.Add(new("RecoverySafe", MaintenanceText.Safe));
            lines.Add(new("RecoverySafeDetail", MaintenanceText.SafeDetail));
            bool details = false;
            if (!string.IsNullOrEmpty(verdict?.Details)) { lines.Add(new("RecoveryDetails", verdict.Details)); details = true; }
            if (!string.IsNullOrEmpty(verdict?.Phase)) { lines.Add(new("RecoveryStage", MaintenanceText.Stage(verdict.Phase))); details = true; }
            if (verdict?.LogTail is { Count: > 0 }) { lines.Add(new("RecoveryLogDetails", MaintenanceText.LogDetails)); lines.Add(new("RecoveryLog", MaintenanceText.LogTail(verdict))); details = true; }
            if (!details) lines.Add(new("RecoveryNoDetails", MaintenanceText.NoDetails));
            if (boot is not null) lines.Add(new("RecoveryBootState", MaintenanceText.BootState(boot.BootState, brand)));
            else if (state == MaintenanceGateState.Opening) lines.Add(new("RecoveryBootState", MaintenanceText.CheckingBoot));
            if (boot is not null)
            {
                var bootLines = MaintenanceText.BootLines(boot);
                for (int index = 0; index < bootLines.Count; index++) lines.Add(new($"RecoveryBootLine{index}", bootLines[index]));
            }
            buttons.Add(new("ReadInstallation", ReadDetails, readable));
            buttons.Add(new("RemoveLinux", MaintenanceText.Remove(brand), open));
            buttons.Add(new("KeepWindowsOnly", MaintenanceText.KeepWindows, open && MaintenanceText.CanRestoreWindows(boot)));
            buttons.Add(new("RepairBoot", MaintenanceText.RepairBoot, open && MaintenanceText.CanRepairBoot(boot)));
            // The engine admits Try again only for a recorded attempt; the button mirrors it.
            buttons.Add(new("TryAgain", MaintenanceText.TryAgain, open && verdict?.CanTryAgain == true));
        }
        string status = state switch
        {
            MaintenanceGateState.Opening => RequestingPermission,
            MaintenanceGateState.Preparing => CheckingAction,
            MaintenanceGateState.Confirming => Working,
            MaintenanceGateState.Refused => gate!.Reason,
            MaintenanceGateState.Completed => MaintenanceText.Outcome(gate!.CompletedAction ?? "", route == StartupRoute.Recovery, brand, null),
            MaintenanceGateState.Failed => MaintenanceText.Outcome(gate!.LastAction ?? "", route == StartupRoute.Recovery, brand, gate.Reason),
            _ => "",
        };
        return new MaintenanceView(lines, buttons, offerDelete, offerPartition, status);
    }
}
