using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class MaintenanceGateTests
{
    private const string Brand = "fixture-brand";
    private const string Intent = "0123456789abcdef0123456789abcdef";

    internal sealed class FakeMaintenanceSession : IMaintenanceEngineSession
    {
        public string SessionId = "";
        public UninstallInfo Info = new() { Found = true, StorageDrive = "D", DiskPath = @"D:\wootc\disks\root.disk", DiskSizeGB = 64, OnDedicatedVol = true, ReclaimGB = 80, VolumeLabel = "wootc-data", Deployed = true };
        public BootRepairReport Boot = new() { BootState = "wootc-listed", CanRestoreWindows = true, CanRepairBoot = true };
        public Func<NativeMaintenancePlan, string, NativeMaintenanceGrant> Grant = (plan, session) => new NativeMaintenanceGrant
        {
            SchemaVersion = 1, Session = session, BrandId = Brand, IntentId = Intent, Action = plan.Action,
            DeleteRootDisk = plan.DeleteRootDisk, RemovePartition = plan.RemovePartition, DiskPath = @"D:\wootc\disks\root.disk", StorageDrive = "D", VolumeLabel = "wootc-data",
        };
        public Exception? Refusal, ConfirmFailure;
        public readonly List<NativeMaintenancePlan> Plans = new();
        public readonly List<NativeMaintenanceGrant> Confirmed = new();
        public int Inspections, Disposed;
        public Task<UninstallInfo> ReadUninstallInfoAsync(CancellationToken token) => Task.FromResult(Info);
        public Task<BootRepairReport> InspectBootAsync(CancellationToken token) { Inspections++; return Task.FromResult(Boot); }
        public Task<NativeMaintenanceGrant> PrepareMaintenanceAsync(NativeMaintenancePlan plan, CancellationToken token)
        {
            Plans.Add(plan);
            return Refusal is null ? Task.FromResult(Grant(plan, SessionId)) : Task.FromException<NativeMaintenanceGrant>(Refusal);
        }
        public Task ConfirmMaintenanceAsync(NativeMaintenanceGrant grant, CancellationToken token)
        {
            Confirmed.Add(grant);
            return ConfirmFailure is null ? Task.CompletedTask : Task.FromException(ConfirmFailure);
        }
        public Task<StartupSnapshot> ReadStartupAsync(CancellationToken token) => throw new InvalidOperationException("A maintenance session has no startup read");
        public ValueTask DisposeAsync() { Disposed++; return ValueTask.CompletedTask; }
    }

    internal sealed class FakeConnector : IEngineConnector
    {
        public readonly List<ConnectRequest> Requests = new();
        public readonly List<FakeMaintenanceSession> Sessions = new();
        public ConnectionOutcome Outcome = ConnectionOutcome.Connected;
        public Action<FakeMaintenanceSession>? Configure;
        public Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken token)
        {
            Requests.Add(request);
            if (Outcome != ConnectionOutcome.Connected) return Task.FromResult(new ConnectionAttempt(Outcome, Reason: "Administrator permission was declined. You can retry."));
            var session = new FakeMaintenanceSession { SessionId = request.SessionId };
            Configure?.Invoke(session);
            Sessions.Add(session);
            return Task.FromResult(new ConnectionAttempt(ConnectionOutcome.Connected, session));
        }
    }

    private static NativeMaintenancePlan Plan(string action, bool delete = false, bool partition = false) => new() { Action = action, DeleteRootDisk = delete, RemovePartition = partition };

    [Fact]
    public async Task AnActionNeedsAnOpenInstallSessionAndAMatchingGrant()
    {
        var connector = new FakeConnector();
        await using var gate = new MaintenanceGate(connector, Brand);
        await Assert.ThrowsAsync<InvalidOperationException>(() => gate.PrepareAsync(Plan(MaintenanceActions.Uninstall)));
        Assert.Empty(connector.Requests);
        await gate.OpenAsync();
        Assert.True(Assert.Single(connector.Requests).Install);
        Assert.Equal(MaintenanceGateState.Observed, gate.State);
        Assert.Equal(@"D:\wootc\disks\root.disk", gate.Info!.DiskPath);
        Assert.Equal(1, connector.Sessions[0].Inspections);
        Assert.False(gate.CanConfirm);
        await gate.PrepareAsync(Plan(MaintenanceActions.Uninstall, delete: true));
        Assert.True(gate.CanConfirm);
        Assert.Empty(connector.Sessions[0].Confirmed);
        await gate.ConfirmAsync();
        var confirmed = Assert.Single(connector.Sessions[0].Confirmed);
        Assert.True(confirmed.DeleteRootDisk);
        Assert.Equal(MaintenanceGateState.Completed, gate.State);
        Assert.Equal(MaintenanceActions.Uninstall, gate.CompletedAction);
        Assert.Equal(1, connector.Sessions[0].Disposed);
        // A used session cannot take a second plan; a new action reopens.
        await Assert.ThrowsAsync<InvalidOperationException>(() => gate.PrepareAsync(Plan(MaintenanceActions.RepairBoot)));
        await gate.OpenAsync();
        Assert.Equal(2, connector.Requests.Count);
        Assert.NotEqual(connector.Requests[0].SessionId, connector.Requests[1].SessionId);
    }

    public static TheoryData<string> Mismatches() => new() { "session", "brand", "intent", "schema", "action", "delete", "partition" };

    [Theory]
    [MemberData(nameof(Mismatches))]
    public async Task AGrantForAnotherPlanOrSessionIsRefused(string field)
    {
        var connector = new FakeConnector
        {
            Configure = session =>
            {
                var granted = session.Grant;
                session.Grant = (plan, id) =>
                {
                    var grant = granted(plan, id);
                    switch (field)
                    {
                        case "session": grant.Session = new string('f', 32); break;
                        case "brand": grant.BrandId = "another-brand"; break;
                        case "intent": grant.IntentId = "not-an-intent"; break;
                        case "schema": grant.SchemaVersion = 2; break;
                        case "action": grant.Action = MaintenanceActions.RepairBoot; break;
                        case "delete": grant.DeleteRootDisk = true; break;
                        case "partition": grant.RemovePartition = true; break;
                    }
                    return grant;
                };
            },
        };
        await using var gate = new MaintenanceGate(connector, Brand);
        await gate.OpenAsync();
        await gate.PrepareAsync(Plan(MaintenanceActions.Uninstall));
        Assert.Equal(MaintenanceGateState.Refused, gate.State);
        Assert.False(gate.CanConfirm);
        Assert.Equal(1, connector.Sessions[0].Disposed);
        Assert.Empty(connector.Sessions[0].Confirmed);
    }

    [Fact]
    public async Task DecliningOrARefusalClosesTheSessionAndAFailureIsReported()
    {
        var connector = new FakeConnector();
        await using var gate = new MaintenanceGate(connector, Brand);
        await gate.OpenAsync();
        await gate.PrepareAsync(Plan(MaintenanceActions.Uninstall));
        await gate.DeclineAsync();
        Assert.Equal(MaintenanceGateState.Idle, gate.State);
        Assert.Equal(1, connector.Sessions[0].Disposed);
        Assert.Empty(connector.Sessions[0].Confirmed);

        connector.Configure = session => session.Refusal = new InvalidDataException("repair refused, nothing was changed: synthetic");
        await gate.OpenAsync();
        await gate.PrepareAsync(Plan(MaintenanceActions.RepairBoot));
        Assert.Equal(MaintenanceGateState.Refused, gate.State);
        Assert.Equal("repair refused, nothing was changed: synthetic", gate.Reason);

        connector.Configure = session => { session.ConfirmFailure = new InvalidDataException("synthetic repair failure"); session.Boot = new BootRepairReport { BootState = "windows-only" }; };
        await gate.OpenAsync();
        await gate.PrepareAsync(Plan(MaintenanceActions.RepairBoot));
        await gate.ConfirmAsync();
        Assert.Equal(MaintenanceGateState.Failed, gate.State);
        Assert.Equal("synthetic repair failure", gate.Reason);
        Assert.Equal(MaintenanceActions.RepairBoot, gate.LastAction);
        // The boot check is read again after a boot action, as the legacy screen did.
        Assert.Equal(2, connector.Sessions[2].Inspections);
        Assert.Equal(1, connector.Sessions[2].Disposed);
    }

    [Fact]
    public async Task ADeclinedPermissionLeavesNothingOpen()
    {
        var connector = new FakeConnector { Outcome = ConnectionOutcome.PermissionDeclined };
        await using var gate = new MaintenanceGate(connector, Brand);
        await gate.OpenAsync();
        Assert.Equal(MaintenanceGateState.Refused, gate.State);
        Assert.Null(gate.Info);
        Assert.Contains("declined", gate.Reason);
    }
}

public sealed class MaintenanceScreenTests
{
    private static readonly Branding Brand = new() { ProductName = "Fixture Installer", Name = "Fixture OS" };
    private static StartupSnapshot Snapshot(string lifecycle = "", RecoveryVerdict? verdict = null) =>
        new(new InstallStatus { Existing = true }, verdict, new LifecycleState { State = lifecycle, PhaseId = lifecycle == "failed" ? "installer.synthetic" : null });

    private static async Task<MaintenanceGate> Opened(Action<MaintenanceGateTests.FakeMaintenanceSession>? configure = null)
    {
        var gate = new MaintenanceGate(new MaintenanceGateTests.FakeConnector { Configure = configure }, "fixture-brand");
        await gate.OpenAsync();
        return gate;
    }

    private static string Line(MaintenanceView view, string id) => Assert.Single(view.Lines, line => line.Id == id).Text;
    private static bool Enabled(MaintenanceView view, string id) => Assert.Single(view.Buttons, button => button.Id == id).Enabled;

    [Fact]
    public async Task ManageShowsTheInstallationOnlyAfterTheSessionReadIt()
    {
        var before = MaintenanceScreen.For(StartupRoute.Manage, Snapshot("failed"), null, Brand, id => id == "installer.synthetic" ? "Synthetic step" : id)!;
        Assert.Equal("Manage Fixture OS", Line(before, "ManageTitle"));
        Assert.Contains("(stopped at \"Synthetic step\")", Line(before, "ManageFailedAttempt"));
        Assert.DoesNotContain(before.Lines, line => line.Id == "ManageCardTitle");
        Assert.False(Enabled(before, "UninstallLinux"));
        Assert.True(Enabled(before, "ReadInstallation"));
        Assert.False(before.OfferDeleteData);

        await using var gate = await Opened();
        var after = MaintenanceScreen.For(StartupRoute.Manage, Snapshot(), gate, Brand, id => id)!;
        Assert.Equal(@"D:\wootc\disks\root.disk (64 GB)", Line(after, "ManageCardTitle"));
        Assert.Equal("Fixture OS boot verified", Line(after, "ManageInstalledTitle"));
        Assert.True(Enabled(after, "UninstallLinux"));
        Assert.True(Enabled(after, "RestartIntoLinux"));
        Assert.False(Enabled(after, "ReadInstallation"));
        Assert.True(after.OfferDeleteData);
        Assert.True(after.OfferPartition);
        Assert.DoesNotContain(after.Lines, line => line.Id == "ManageFailedAttempt");
    }

    [Theory]
    [InlineData("verified", true)]
    [InlineData("missing", false)]
    [InlineData("mismatch", false)]
    public async Task InstalledFactsExposeOnlyActualVerifiedBootAssessment(string verdict, bool visible)
    {
        await using var gate = await Opened(session => session.Info.BootEvidence = new FirstBootAssessment
        {
            Verdict = verdict, Kernel = "6.12.1", SourceImageRef = "ghcr.io/example/linux:stable", BootId = "01234567-89ab-cdef-0123-456789abcdef",
            Bridge = new FirstBootBridge { BoundFolders = 4, MatchedUsers = 2, BitlockerUnlocked = true },
        });
        var view = MaintenanceScreen.For(StartupRoute.Manage, Snapshot(), gate, Brand, id => id)!;
        var facts = view.Lines.Where(line => line.ReadOnlyValue).ToArray();
        Assert.Equal(visible ? 4 : 0, facts.Length);
        if (!visible) return;
        Assert.Equal("6.12.1", Line(view, "InstalledBootKernel"));
        Assert.Equal("ghcr.io/example/linux:stable", Line(view, "InstalledBootSource"));
        Assert.Equal("boundFolders=4;matchedUsers=2;bitlockerUnlocked=true", Line(view, "InstalledBootBridge"));
        Assert.Equal("01234567-89ab-cdef-0123-456789abcdef", Line(view, "InstalledBootId"));
    }

    [Fact]
    public async Task ManageNamesLeftoverBootFilesAndKeepsAUnremovableVolume()
    {
        await using var gate = await Opened(session => session.Info = new UninstallInfo { Orphaned = true, PartitionRemovalReason = "synthetic engine reason" });
        var view = MaintenanceScreen.For(StartupRoute.Manage, Snapshot(), gate, Brand, id => id)!;
        Assert.Equal(MaintenanceText.OrphanedTitle, Line(view, "ManageCardTitle"));
        Assert.Equal("synthetic engine reason", Line(view, "ManagePartitionReason"));
        Assert.False(view.OfferPartition);
        Assert.DoesNotContain(view.Buttons, button => button.Id == "RestartIntoLinux");
    }

    [Fact]
    public async Task RecoveryEnablesOnlyWhatTheBootCheckOffers()
    {
        var verdict = new RecoveryVerdict { Verdict = "failed", Title = "Engine title", Message = "Engine message", Phase = "synthetic-phase", LogTail = Enumerable.Range(1, 12).Select(n => $"line {n}").ToList() };
        var before = MaintenanceScreen.For(StartupRoute.Recovery, Snapshot(verdict: verdict), null, Brand, id => id)!;
        Assert.Equal("Engine title", Line(before, "RecoveryTitle"));
        Assert.Equal("Stage: synthetic-phase", Line(before, "RecoveryStage"));
        Assert.StartsWith("line 3\n", Line(before, "RecoveryLog"));
        Assert.DoesNotContain(before.Lines, line => line.Id == "RecoveryBootState");
        Assert.All(before.Buttons.Where(button => button.Id != "ReadInstallation"), button => Assert.False(button.Enabled));

        await using var gate = await Opened(session => session.Boot = new BootRepairReport { BootState = "wootc-default", CanRepairBoot = true, Findings = ["synthetic finding"], Refusals = ["synthetic refusal"], BundlePath = @"C:\wootc\install\repair\synthetic" });
        var view = MaintenanceScreen.For(StartupRoute.Recovery, Snapshot(verdict: new RecoveryVerdict()), gate, Brand, id => id)!;
        Assert.Equal("Could not finish setting up Fixture OS this time", Line(view, "RecoveryTitle"));
        Assert.Equal(MaintenanceText.NoDetails, Line(view, "RecoveryNoDetails"));
        Assert.Equal("A startup entry from Fixture Installer is ahead of Windows in the boot order.", Line(view, "RecoveryBootState"));
        Assert.Equal(["synthetic finding", "Not offered: synthetic refusal", @"Details saved to C:\wootc\install\repair\synthetic"], view.Lines.Where(line => line.Id.StartsWith("RecoveryBootLine")).Select(line => line.Text));
        Assert.True(Enabled(view, "RepairBoot"));
        Assert.False(Enabled(view, "KeepWindowsOnly"));
        Assert.True(Enabled(view, "RemoveLinux"));
        Assert.False(Enabled(view, "TryAgain"));
        Assert.True(Enabled(MaintenanceScreen.For(StartupRoute.Recovery, Snapshot(verdict: new RecoveryVerdict { Verdict = "failed", CanTryAgain = true }), gate, Brand, id => id)!, "TryAgain"));
    }

    [Fact]
    public async Task TheOutcomeUsesTheLegacyWordsOfTheScreenItCameFrom()
    {
        await using var gate = await Opened(session => session.ConfirmFailure = new InvalidDataException("synthetic"));
        await gate.PrepareAsync(new NativeMaintenancePlan { Action = MaintenanceActions.Uninstall });
        await gate.ConfirmAsync();
        Assert.Equal("Removal encountered an error: synthetic", MaintenanceScreen.For(StartupRoute.Recovery, Snapshot(), gate, Brand, id => id)!.Status);
        Assert.Equal("Uninstall hit a problem: synthetic", MaintenanceScreen.For(StartupRoute.Manage, Snapshot(), gate, Brand, id => id)!.Status);
        Assert.Null(MaintenanceScreen.For(StartupRoute.Assessment, Snapshot(), gate, Brand, id => id));
    }
}

public sealed class MaintenanceTextTests
{
    private static readonly Branding Brand = new() { ProductName = "@PRODUCT@", Name = "@DISTRO@" };

    [Fact]
    public void ConfirmationReflectsTheGrantedDataAndPartitionRemovalChoices()
    {
        var grant = new NativeMaintenanceGrant { Action = MaintenanceActions.Uninstall, VolumeLabel = "@LABEL@", StorageDrive = "@DRIVE@" };
        Assert.Equal(MaintenanceText.ConfirmUninstallHead(Brand) + MaintenanceText.ConfirmKeepData, MaintenanceText.ConfirmUninstall(Brand, grant));
        grant.DeleteRootDisk = grant.RemovePartition = true;
        Assert.Equal(MaintenanceText.ConfirmUninstallHead(Brand) + MaintenanceText.ConfirmDeleteData + MaintenanceText.ConfirmRemovePartition(grant), MaintenanceText.Confirmation(grant, recovery: false, Brand));
        Assert.Equal(MaintenanceText.ConfirmRemove(Brand), MaintenanceText.Confirmation(grant, recovery: true, Brand));
        Assert.Null(MaintenanceText.Confirmation(new NativeMaintenanceGrant { Action = MaintenanceActions.RepairBoot }, recovery: true, Brand));
    }

}
