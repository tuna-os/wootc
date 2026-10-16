using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class InstallRecoveryRouteTests
{
    private static StartupSnapshot Snapshot(string installClass, string verdict = "", bool existing = true, string lifecycle = "staged") =>
        new(new InstallStatus { Existing = existing }, new RecoveryVerdict { Verdict = verdict }, new LifecycleState { State = lifecycle },
            new InstallRecoverySummary { Class = installClass });

    [Theory]
    [InlineData("resumable")]
    [InlineData("failed")]
    [InlineData("needs-repair")]
    public void InterruptedClassesRouteToInterrupted(string installClass) =>
        Assert.Equal(StartupRoute.Interrupted, StartupController.SelectRoute(Snapshot(installClass)));

    [Theory]
    [InlineData("none", false, StartupRoute.Assessment)]
    [InlineData("none", true, StartupRoute.Manage)]
    [InlineData("complete", true, StartupRoute.Manage)]
    [InlineData("in-progress", true, StartupRoute.Manage)]
    public void OtherClassesKeepTheExistingRoutes(string installClass, bool existing, StartupRoute expected) =>
        Assert.Equal(expected, StartupController.SelectRoute(Snapshot(installClass, existing: existing)));

    [Fact]
    public void ABootVerdictWinsOverTheJournalLikeTheLegacyRelaunch() =>
        Assert.Equal(StartupRoute.Recovery, StartupController.SelectRoute(Snapshot("resumable", verdict: "interrupted")));

    [Fact]
    public void ARunningInstallWinsOverTheJournal() =>
        Assert.Equal(StartupRoute.Progress, StartupController.SelectRoute(new(new InstallStatus { Running = true }, null, null, new InstallRecoverySummary { Class = "failed" })));

    [Fact]
    public void AnAbsentObservationIsNoAttempt() =>
        Assert.Equal(StartupRoute.Assessment, StartupController.SelectRoute(new(new InstallStatus(), null)));

    [Theory]
    [InlineData("")]
    [InlineData("Resumable")]
    [InlineData("healthy")]
    public void AnUnsupportedClassIsRefused(string installClass) =>
        Assert.Throws<InvalidDataException>(() => StartupController.SelectRoute(Snapshot(installClass)));
}
