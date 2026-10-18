using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class E2EDriveLoopTests
{
    private const string Run = "20261015-native-fixture";
    private const string Reference = "ghcr.io/tuna-os/yellowfin:gnome";

    private static string Golden(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "e2e-drive", name));

    private sealed class FakeChannel : IE2EDriveChannel
    {
        public string Directive { get; set; } = "";
        public bool FailReads { get; set; }
        public List<string> Reports { get; } = [];
        public List<string> Ready { get; } = [];
        public Task<string> ReadDirectiveAsync(CancellationToken cancellationToken) =>
            FailReads ? Task.FromException<string>(new IOException("transient")) : Task.FromResult(Directive);
        public Task ReportAsync(string state, CancellationToken cancellationToken) { Reports.Add(state); return Task.CompletedTask; }
        public Task ReadyAsync(string state, CancellationToken cancellationToken) { Ready.Add(state); return Task.CompletedTask; }
    }

    // A window stand-in over the real configuration view-model.
    private sealed class FakeView : IE2EDriveView
    {
        public ConsumerConfiguration Model { get; }
        public DriveScreen Screen { get; set; } = DriveScreen.Launchpad;
        public string ProgressStep { get; set; } = "";
        public string? Error { get; set; }
        public bool ClickStarts { get; set; } = true;
        // The window asks the engine for the selected image's install space
        // after each form change; null leaves that read unanswered.
        public int? ReserveGb { get; set; } = ConsumerConfiguration.MinimumInstallReserveGb;
        public int Maps, Clicks, Reboots;

        public FakeView(params ConfigurationStorage[] volumes)
        {
            Model = new ConsumerConfiguration("fixture-brand");
            Model.ApplyCatalogue(new ConfigurationCatalogue(1, "fixture-brand", "embedded", new string('a', 64),
                new[] { new ConfigurationImage("yellowfin", "Yellowfin GNOME", Reference, "green", true, "", false, "", false) },
                "alpha", false, new ConfigurationDefaults(40, "tpm2-luks", "auto", false, false),
                volumes.Length == 0 ? new[] { Volume("observed-c", "C") } : volumes));
        }

        public DriveObservation Observe() => Screen == DriveScreen.Launchpad
            ? new(Screen, Model.FormProblem.Length != 0 || Checking,
                Checking ? InstallGateText.Status(InstallGateState.Preparing, "", TimeSpan.FromSeconds(45)) : Model.FormProblem,
                "", Error, Model.SelectedImage?.ImageRef ?? "", Model.ObservedStorage)
            : new(Screen, null, "", ProgressStep, Error, Model.SelectedImage?.ImageRef ?? "", Model.ObservedStorage);

        public DriveMappingObservation MapInstall(E2EDriveDirective directive)
        {
            Maps++;
            var outcome = Model.ApplyDriveMapping(directive.ToInstallMapping(), directive.RunId);
            AnswerInstallSpace();
            return outcome;
        }

        public void AnswerInstallSpace()
        {
            if (ReserveGb is int reserve && Model.PendingInstallSpace is var (imageRef, drive))
                Model.ApplyInstallSpace(new(imageRef, drive, reserve, "registry"));
        }

        // Set to hold the click in the engine's plan check until the test answers.
        public TaskCompletionSource<bool>? PlanCheck { get; set; }
        // Clicked, and the engine has not answered: both controls are disabled.
        private bool Checking => Clicks > 0 && PlanCheck is { Task.IsCompleted: false };
        public Task<bool> ClickInstallAsync() { Clicks++; return PlanCheck?.Task ?? Task.FromResult(ClickStarts); }
        public Task RebootAsync() { Reboots++; return Task.CompletedTask; }
    }

    private static ConfigurationStorage Volume(string id, string letter) => new(id, letter,
        "11111111-1111-1111-1111-111111111111", Guid.NewGuid().ToString(), "0123456789abcdef", 256L * 1024 * 1024 * 1024, 200);

    // Native run 38902999307: the directive named no disk size, the form kept
    // the catalogue's 40 GB on a drive with 58 GB free, and the engine
    // refused the plan. The drive must wait for the image's install space,
    // then click with the size the form lowered to fit.
    [Fact]
    public async Task TheDriveWaitsForTheInstallSpaceAndInstallsWhatFits()
    {
        const long gib = 1L << 30;
        var channel = new FakeChannel();
        var view = new FakeView(new ConfigurationStorage("observed-c", "C", "11111111-1111-1111-1111-111111111111",
            Guid.NewGuid().ToString(), "0123456789abcdef", 58 * gib + gib / 2, 58)) { ReserveGb = null };
        var directive = System.Text.Json.Nodes.JsonNode.Parse(Golden("directive-install.json"))!.AsObject();
        directive.Remove("diskSizeGb");
        channel.Directive = directive.ToJsonString();
        var loop = new E2EDriveLoop(channel, view);
        await loop.TickAsync();
        Assert.Equal(1, view.Maps);
        await loop.TickAsync();
        await loop.TickAsync();
        Assert.Equal(0, view.Clicks);
        Assert.Contains("Checking how much working space", view.Observe().Hint);

        view.ReserveGb = ConsumerConfiguration.MinimumInstallReserveGb;
        view.AnswerInstallSpace();
        Assert.Equal(35, view.Model.DiskSizeGb);
        Assert.Empty(view.Model.FormProblem);
        await loop.TickAsync();
        Assert.Equal(1, view.Clicks);
        Assert.Equal(35, view.Model.CreateDraft().DiskSizeGB);
    }

    // Native E2E runs 38923119161 and 38931058878: the tick that clicked
    // Install awaited the whole plan check (a second elevation, then
    // PrepareNativeInstall), so no tick ran and no report was written for
    // about two minutes. The click now runs beside the loop: every tick
    // still reports, the clicked control is neither offered nor refused,
    // and the outcome is settled once the engine answers.
    [Fact]
    public async Task APlanCheckInFlightNeverStopsTheReports()
    {
        var channel = new FakeChannel { Directive = Golden("directive-install.json") };
        var view = new FakeView { PlanCheck = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously) };
        var loop = new E2EDriveLoop(channel, view);
        await Tick(loop); // maps the form
        await Tick(loop); // clicks Install; the plan check starts
        Assert.Equal(1, view.Clicks);
        Assert.True(loop.InstallPending);
        int before = channel.Reports.Count;
        for (int tick = 0; tick < 3; tick++) await Tick(loop);
        Assert.Equal(before + 3, channel.Reports.Count);
        Assert.Equal(1, view.Clicks);
        // The window disables both install controls while the check runs;
        // the report says the check is pending, not that Install is refused.
        Assert.True(view.Observe().InstallButtonDisabled);
        Assert.Equal(Golden("report-install-checking.json"), channel.Reports[^1]);

        view.PlanCheck.SetResult(true);
        view.Screen = DriveScreen.Progress;
        await Tick(loop);
        Assert.False(loop.InstallPending);
        Assert.True(loop.Session.InstallDriven);
        Assert.Contains("\"installDriven\":true", channel.Reports[^1]);
        Assert.Equal(1, view.Clicks);
    }

    // A plan check that ends without an install is the drive error, as when
    // the click answered at once, and Install is never clicked again.
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task APlanCheckThatEndsWithoutAnInstallIsTheDriveError(bool faults)
    {
        var channel = new FakeChannel { Directive = Golden("directive-install.json") };
        var view = new FakeView { PlanCheck = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously) };
        var loop = new E2EDriveLoop(channel, view);
        for (int tick = 0; tick < 3; tick++) await Tick(loop);
        Assert.Null(loop.Session.DriveError);
        if (faults) view.PlanCheck.SetException(new IOException("engine went away"));
        else view.PlanCheck.SetResult(false);
        await Tick(loop);
        await Tick(loop);
        Assert.Equal(1, view.Clicks);
        Assert.False(loop.InstallPending);
        Assert.Contains(faults ? "\"error\":\"The install could not start: engine went away\"" : "\"error\":\"The engine did not grant this plan", channel.Reports[^1]);
    }

    // A tick that waits on the engine is the bug these tests reproduce: fail
    // it in seconds rather than hang the run.
    private static async Task Tick(E2EDriveLoop loop)
    {
        var tick = loop.TickAsync();
        Assert.True(ReferenceEquals(tick, await Task.WhenAny(tick, Task.Delay(TimeSpan.FromSeconds(5)))), "A drive tick waited on the engine");
        await tick;
    }

    [Fact]
    public async Task WithoutADirectiveOnlyReadinessIsSignalled()
    {
        var channel = new FakeChannel();
        var view = new FakeView { Screen = DriveScreen.Loading };
        var loop = new E2EDriveLoop(channel, view);
        await loop.TickAsync();
        Assert.Equal(["{\"schemaVersion\":1,\"screen\":\"loading\"}"], channel.Ready);
        Assert.Empty(channel.Reports);
        channel.FailReads = true;
        await loop.TickAsync();
        Assert.Equal(2, channel.Ready.Count);
        Assert.Empty(channel.Reports);
    }

    [Fact]
    public async Task DrivesInstallAndRebootThroughTheViewAndReportsTheGoldens()
    {
        var channel = new FakeChannel { Directive = "﻿" + Golden("directive-install.json") };
        var view = new FakeView();
        var loop = new E2EDriveLoop(channel, view);

        await loop.TickAsync(); // maps the form
        Assert.Equal((1, 0), (view.Maps, view.Clicks));
        Assert.Equal("C", view.Model.SelectedStorage!.DriveLetter);
        Assert.Equal("none", view.Model.Encryption);
        Assert.Empty(view.Model.FormProblem);
        Assert.Equal(Golden("report-install-ready.json"), channel.Reports[^1]);

        await loop.TickAsync(); // clicks Install once
        await loop.TickAsync();
        Assert.Equal((1, 1), (view.Maps, view.Clicks));
        Assert.True(loop.Session.InstallDriven);

        view.Screen = DriveScreen.Done;
        view.ProgressStep = "armed";
        await loop.TickAsync();
        Assert.Equal(Golden("report-install-done.json"), channel.Reports[^1]);

        channel.Directive = Golden("directive-reboot.json");
        await loop.TickAsync();
        await loop.TickAsync();
        Assert.Equal(1, view.Reboots);
        Assert.Equal(Golden("report-reboot-done.json"), channel.Reports[^1]);
        Assert.Empty(channel.Ready);
    }

    [Fact]
    public async Task ARefusedTargetIsReportedAndNothingIsMappedOrClicked()
    {
        var channel = new FakeChannel { Directive = Golden("directive-install.json") };
        var view = new FakeView(Volume("observed-d", "D"));
        var loop = new E2EDriveLoop(channel, view);
        await loop.TickAsync();
        await loop.TickAsync();
        Assert.Equal((0, 0), (view.Maps, view.Clicks));
        Assert.Equal(Golden("report-install-unknown-target.json"), channel.Reports[^1]);
    }

    [Fact]
    public async Task AnUnstartedInstallIsNeverClickedAgain()
    {
        var channel = new FakeChannel { Directive = Golden("directive-install.json") };
        var view = new FakeView { ClickStarts = false };
        var loop = new E2EDriveLoop(channel, view);
        for (int tick = 0; tick < 4; tick++) await loop.TickAsync();
        Assert.Equal(1, view.Clicks);
        Assert.False(loop.Session.InstallDriven);
        Assert.Contains("\"installDriven\":false", channel.Reports[^1]);
    }

    // Native E2E run 38849303170: the plan check failed, the form stayed
    // disabled, and the report carried no error, so the harness could only
    // time out. An install that did not start is reported as the drive error.
    [Fact]
    public async Task AnInstallThatDidNotStartIsReportedAsTheDriveError()
    {
        var channel = new FakeChannel { Directive = Golden("directive-install.json") };
        var view = new FakeView { ClickStarts = false };
        var loop = new E2EDriveLoop(channel, view);
        for (int tick = 0; tick < 3; tick++) await loop.TickAsync();
        Assert.Equal(1, view.Clicks);
        Assert.Contains("did not grant this plan", loop.Session.DriveError);
        Assert.Contains("\"error\":\"The engine did not grant this plan", channel.Reports[^1]);
    }

    [Fact]
    public async Task TheViewsOwnErrorIsTheDriveErrorWhenTheInstallDidNotStart()
    {
        var channel = new FakeChannel { Directive = Golden("directive-install.json") };
        var view = new FakeView { ClickStarts = false };
        var loop = new E2EDriveLoop(channel, view);
        await loop.TickAsync();
        view.Error = "The engine did not finish checking this plan in time.";
        await loop.TickAsync();
        Assert.Equal("The engine did not finish checking this plan in time.", loop.Session.DriveError);
        view.Error = null;
        await loop.TickAsync();
        Assert.Contains("\"error\":\"The engine did not finish checking this plan in time.\"", channel.Reports[^1]);
    }

    [Fact]
    public async Task AFailedMappingIsReportedAsTheDriveError()
    {
        var channel = new FakeChannel { Directive = Golden("directive-install.json") };
        var view = new ThrowingView(new FakeView());
        var loop = new E2EDriveLoop(channel, view);
        await loop.TickAsync();
        Assert.Contains("\"error\":\"The drive directive could not be mapped: view went away\"", channel.Reports[^1]);
        await loop.TickAsync();
        Assert.Equal(0, view.Clicks);
    }

    private sealed class ThrowingView(FakeView inner) : IE2EDriveView
    {
        public int Clicks;
        public DriveObservation Observe() => inner.Observe();
        public DriveMappingObservation MapInstall(E2EDriveDirective directive) => throw new InvalidOperationException("view went away");
        public Task<bool> ClickInstallAsync() { Clicks++; return Task.FromResult(true); }
        public Task RebootAsync() => Task.CompletedTask;
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("{\"schemaVersion\":1}")]
    public async Task AMalformedDirectiveIsNeitherFollowedNorReported(string raw)
    {
        var channel = new FakeChannel { Directive = raw };
        var view = new FakeView();
        await new E2EDriveLoop(channel, view).TickAsync();
        Assert.Empty(channel.Reports);
        Assert.Empty(channel.Ready);
        Assert.Equal(0, view.Maps);
    }

    [Fact]
    public async Task AnotherRunIsNeverFollowed()
    {
        var channel = new FakeChannel { Directive = Golden("directive-install.json") };
        var view = new FakeView();
        var loop = new E2EDriveLoop(channel, view);
        await loop.TickAsync();
        int reports = channel.Reports.Count;
        channel.Directive = Golden("directive-install.json").Replace(Run, "another-run");
        await loop.TickAsync();
        Assert.Equal(reports, channel.Reports.Count);
        Assert.Equal((1, 0), (view.Maps, view.Clicks));
    }

    // The controller is the window's channel. It never waits behind another
    // engine call and never answers without an authenticated drive session.
    [Fact]
    public async Task TheControllerCarriesTheChannelOnlyWhenConnected()
    {
        var session = new DriveSession();
        var connector = new Connector(new(ConnectionOutcome.Connected, session));
        await using var controller = new StartupController(new Branding { ProductName = "Fixture Installer", Name = "Fixture" }, connector);
        await Assert.ThrowsAsync<InvalidOperationException>(() => controller.ReadDirectiveAsync(CancellationToken.None));
        await controller.RequestPermissionAsync();
        Assert.Equal("directive", await controller.ReadDirectiveAsync(CancellationToken.None));
        await controller.ReportAsync("report", CancellationToken.None);
        await controller.ReadyAsync("ready", CancellationToken.None);
        Assert.Equal(["report"], session.Reports);
        Assert.Equal(["ready"], session.Ready);
    }

    private sealed class Connector(ConnectionAttempt attempt) : IEngineConnector
    {
        public Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken cancellationToken) => Task.FromResult(attempt);
    }

    private sealed class DriveSession : IDriveEngineSession
    {
        public List<string> Reports { get; } = [];
        public List<string> Ready { get; } = [];
        public Task<StartupSnapshot> ReadStartupAsync(CancellationToken cancellationToken) =>
            Task.FromResult(new StartupSnapshot(new InstallStatus(), null));
        public Task<string> ReadDriveDirectiveAsync(CancellationToken cancellationToken) => Task.FromResult("directive");
        public Task ReportDriveAsync(string state, CancellationToken cancellationToken) { Reports.Add(state); return Task.CompletedTask; }
        public Task ReportDriveReadyAsync(string state, CancellationToken cancellationToken) { Ready.Add(state); return Task.CompletedTask; }
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
