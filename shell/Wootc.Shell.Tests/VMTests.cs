using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class VMGateTests
{
    private const string Brand = "fixture-brand";
    private const string Intent = "0123456789abcdef0123456789abcdef";
    private static readonly Branding Identity = new() { ProductName = "Fixture Installer", Name = "Fixture OS" };

    internal sealed class FakeVMSession : IVMEngineSession
    {
        public string SessionId = "";
        public Queue<NativeVMStatus> Statuses = new();
        public NativeVMStatus Current = Status("absent", prepare: new NativeVMCapability { Available = true, Accelerator = "whpx" });
        public Func<NativeVMPlan, string, NativeVMGrant> Grant = (plan, session) => new NativeVMGrant
        {
            SchemaVersion = 1, Session = session, BrandId = Brand, IntentId = Intent, Action = plan.Action, ImageRef = plan.ImageRef ?? "", Username = plan.Username ?? "", Phase = "absent",
        };
        public Exception? Refusal, ConfirmFailure;
        public Action? DuringFirstRead;
        public readonly List<NativeVMPlan> Plans = new();
        public readonly List<NativeVMGrant> Confirmed = new();
        public int Disposed, Reads;
        public event Action<VMEvent>? VMProgressReceived;
        public void Emit(VMEvent update) => VMProgressReceived?.Invoke(update);
        public Task<NativeVMStatus> ReadVMStatusAsync(CancellationToken token)
        {
            if (Reads++ == 0) DuringFirstRead?.Invoke();
            return Task.FromResult(Statuses.Count > 0 ? Current = Statuses.Dequeue() : Current);
        }
        public Task<NativeVMGrant> PrepareVMActionAsync(NativeVMPlan plan, CancellationToken token)
        {
            Plans.Add(plan);
            return Refusal is null ? Task.FromResult(Grant(plan, SessionId)) : Task.FromException<NativeVMGrant>(Refusal);
        }
        public Task ConfirmVMActionAsync(NativeVMGrant grant, CancellationToken token)
        {
            Confirmed.Add(grant);
            return ConfirmFailure is null ? Task.CompletedTask : Task.FromException(ConfirmFailure);
        }
        public Task<StartupSnapshot> ReadStartupAsync(CancellationToken token) => throw new InvalidOperationException("A VM session has no startup read");
        public ValueTask DisposeAsync() { Disposed++; return ValueTask.CompletedTask; }
    }

    internal sealed class FakeConnector : IEngineConnector
    {
        public readonly List<ConnectRequest> Requests = new();
        public readonly List<FakeVMSession> Sessions = new();
        public ConnectionOutcome Outcome = ConnectionOutcome.Connected;
        public Action<FakeVMSession>? Configure;
        public Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken token)
        {
            Requests.Add(request);
            if (Outcome != ConnectionOutcome.Connected) return Task.FromResult(new ConnectionAttempt(Outcome, Reason: "Administrator permission was declined. You can retry."));
            var session = new FakeVMSession { SessionId = request.SessionId };
            Configure?.Invoke(session);
            Sessions.Add(session);
            return Task.FromResult(new ConnectionAttempt(ConnectionOutcome.Connected, session));
        }
    }

    internal static NativeVMStatus Status(string phase, NativeVMCapability? launch = null, NativeVMCapability? prepare = null, string error = "") =>
        new() { SchemaVersion = 1, Phase = phase, Error = error, Launch = launch ?? new(), Prepare = prepare ?? new() };

    // The engine's recorded vm:progress stream (app/native_vm_test.go).
    internal static VMEvent[] Recorded() => File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "Fixtures", "native-vm", "progress.ndjson"))
        .Select(line => JsonNode.Parse(line)!["params"]!.Deserialize<VMEvent>()!).ToArray();

    private static NativeVMPlan Prepare() => new() { Action = VMActions.Prepare, ImageRef = "ghcr.io/tuna-os/yellowfin:gnome", Username = "linux_user", Password = "public synthetic password" };

    [Fact]
    public async Task TheSessionStaysOpenAndEachActionNeedsItsOwnGrant()
    {
        var connector = new FakeConnector();
        await using var gate = new VMGate(connector, Brand);
        await Assert.ThrowsAsync<InvalidOperationException>(() => gate.RunAsync(Prepare(), _ => Task.FromResult(true)));
        await gate.OpenAsync();
        Assert.True(Assert.Single(connector.Requests).Install);
        Assert.True(gate.IsOpen);
        var session = connector.Sessions[0];
        Assert.True(await gate.RunAsync(Prepare(), _ => Task.FromResult(true)));
        Assert.Equal("public synthetic password", Assert.Single(session.Plans).Password);
        session.Current = Status("running");
        Assert.True(await gate.RunAsync(new NativeVMPlan { Action = VMActions.Stop }, _ => Task.FromResult(true)));
        Assert.Equal([VMActions.Prepare, VMActions.Stop], session.Confirmed.Select(grant => grant.Action));
        Assert.Equal(0, session.Disposed);
        Assert.Single(connector.Requests);
        await gate.DisposeAsync();
        Assert.Equal(1, session.Disposed);
    }

    public static TheoryData<string> Mismatches() => new() { "session", "brand", "intent", "schema", "action", "image", "user" };

    [Theory]
    [MemberData(nameof(Mismatches))]
    public async Task AGrantForAnotherActionOrSessionIsNotConfirmed(string field)
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
                        case "intent": grant.IntentId = "short"; break;
                        case "schema": grant.SchemaVersion = 2; break;
                        case "action": grant.Action = VMActions.Boot; break;
                        case "image": grant.ImageRef = "ghcr.io/other"; break;
                        case "user": grant.Username = "someone_else"; break;
                    }
                    return grant;
                };
            },
        };
        await using var gate = new VMGate(connector, Brand);
        await gate.OpenAsync();
        bool asked = false;
        Assert.False(await gate.RunAsync(Prepare(), _ => { asked = true; return Task.FromResult(true); }));
        Assert.False(asked);
        Assert.Empty(connector.Sessions[0].Confirmed);
        Assert.Equal(VMGateState.Refused, gate.State);
        Assert.True(gate.IsOpen);
    }

    [Fact]
    public async Task DecliningRefusalsAndFailuresKeepTheSessionAndReportTheEngineText()
    {
        var connector = new FakeConnector();
        await using var gate = new VMGate(connector, Brand);
        await gate.OpenAsync();
        var session = connector.Sessions[0];
        Assert.False(await gate.RunAsync(new NativeVMPlan { Action = VMActions.ForceStop }, _ => Task.FromResult(false)));
        Assert.Empty(session.Confirmed);
        session.Refusal = new InvalidDataException("no active Linux system is owned by this session");
        Assert.False(await gate.RunAsync(new NativeVMPlan { Action = VMActions.ForceStop }, _ => Task.FromResult(true)));
        Assert.Equal("no active Linux system is owned by this session", gate.Reason);
        session.Refusal = null;
        session.ConfirmFailure = new InvalidDataException("synthetic boot failure");
        Assert.False(await gate.RunAsync(new NativeVMPlan { Action = VMActions.Boot }, _ => Task.FromResult(true)));
        Assert.Equal("synthetic boot failure", gate.Reason);
        Assert.Equal(0, session.Disposed);
    }

    [Fact]
    public async Task ProgressIsHeardFromTheFirstReadAndTheRecordedStreamDrivesTheView()
    {
        var connector = new FakeConnector { Configure = session => session.DuringFirstRead = () => session.Emit(new VMEvent { Stage = "pulling", Message = "early" }) };
        await using var gate = new VMGate(connector, Brand);
        await gate.OpenAsync();
        Assert.Equal("early", gate.Progress!.Message);
        var session = connector.Sessions[0];
        await gate.RunAsync(Prepare(), _ => Task.FromResult(true));
        Assert.Null(gate.Progress);
        var titles = new List<string>();
        foreach (var update in Recorded())
        {
            session.Emit(update);
            if (update.Stage == "started") session.Current = Status("running");
            if (update.Stage == "stopped") session.Current = Status("stopped", launch: new NativeVMCapability { Available = true, Accelerator = "whpx" });
            if (update.Stage is "started" or "stopped") await gate.RefreshAsync();
            titles.Add(VMScreen.For(gate, Identity, "Yellowfin", "").Lines.First(line => line.Id == "VMTitle").Text);
        }
        Assert.Equal([VMText.PreparingTitle, VMText.PreparingTitle, VMText.PreparingTitle, VMText.PreparingTitle, VMText.StartingTitle, VMText.StoppedTitle], titles);
    }
}

public sealed class VMScreenTests
{
    private static readonly Branding Brand = new() { ProductName = "Fixture Installer", Name = "Fixture OS" };

    private static async Task<VMGate> Opened(NativeVMStatus status)
    {
        var gate = new VMGate(new VMGateTests.FakeConnector { Configure = session => session.Current = status }, "fixture-brand");
        await gate.OpenAsync();
        return gate;
    }

    private static MaintenanceButton Button(VMView view, string id) => Assert.Single(view.Buttons, button => button.Id == id);
    private static string Line(VMView view, string id) => Assert.Single(view.Lines, line => line.Id == id).Text;

    [Fact]
    public async Task NothingIsOfferedBeforeTheSessionReadsTheStatus()
    {
        var before = VMScreen.For(null, Brand, null, "");
        Assert.True(Button(before, "ReadVMStatus").Enabled);
        Assert.Single(before.Buttons);
        await using var declined = new VMGate(new VMGateTests.FakeConnector { Outcome = ConnectionOutcome.PermissionDeclined }, "fixture-brand");
        await declined.OpenAsync();
        Assert.Contains("declined", Line(VMScreen.For(declined, Brand, null, ""), "VMStatus"));
    }

    [Fact]
    public async Task AnAbsentSystemOffersPreparationOrRuntimeSetupAsTheEngineSays()
    {
        await using var runtime = await Opened(VMGateTests.Status("absent", prepare: new NativeVMCapability { RuntimeNeeded = true, Reason = "This release needs the Linux window runtime." }));
        var view = VMScreen.For(runtime, Brand, null, "");
        Assert.True(Button(view, "SetUpRuntime").Enabled);
        Assert.DoesNotContain(view.Buttons, button => button.Id == "StartInWindow");
        Assert.Equal("This release needs the Linux window runtime.", Line(view, "VMReason"));
        await using var ready = await Opened(VMGateTests.Status("absent", prepare: new NativeVMCapability { Available = true }));
        var blocked = VMScreen.For(ready, Brand, null, VMText.PasswordsDiffer);
        Assert.False(Button(blocked, "StartInWindow").Enabled);
        Assert.Equal(VMText.PasswordsDiffer, Line(blocked, "VMHint"));
        Assert.True(Button(VMScreen.For(ready, Brand, null, ""), "StartInWindow").Enabled);
        Assert.Equal("Start Fixture OS in a window", Button(blocked, "StartInWindow").Label);
    }

    [Fact]
    public async Task APreparedSystemStartsOnlyWhenTheEngineCanLaunchIt()
    {
        await using var ready = await Opened(VMGateTests.Status("ready", launch: new NativeVMCapability { Available = true, Accelerator = "whpx,tcg" }));
        var view = VMScreen.For(ready, Brand, null, "");
        Assert.Equal("Boot your installed Fixture OS in a window using WHPX. Changes persist — it's the same system.", Line(view, "VMMessage"));
        Assert.True(Button(view, "BootInVM").Enabled);
        await using var stopped = await Opened(VMGateTests.Status("stopped", launch: new NativeVMCapability { Reason = "No VM accelerator available. Enable Windows Hypervisor Platform." }));
        var off = VMScreen.For(stopped, Brand, null, "");
        Assert.Equal(VMText.StoppedTitle, Line(off, "VMTitle"));
        Assert.False(Button(off, "StartLinuxAgain").Enabled);
        Assert.StartsWith("No VM accelerator", Line(off, "VMReason"));
        await using var running = await Opened(VMGateTests.Status("running"));
        var on = VMScreen.For(running, Brand, "Yellowfin", "");
        Assert.StartsWith("Yellowfin is starting in its own window.", Line(on, "VMMessage"));
        Assert.True(Button(on, "ShutDownLinux").Enabled && Button(on, "ForceStopLinux").Enabled);
        await using var broken = await Opened(VMGateTests.Status("needs_recovery", error: "The previous VM session did not record a clean stop."));
        var failed = VMScreen.For(broken, Brand, null, "");
        Assert.Equal(VMText.ErrorTitle, Line(failed, "VMTitle"));
        Assert.Empty(failed.Buttons);
    }

    [Fact]
    public async Task OnlyARuntimeDownloadFillsTheBar()
    {
        var connector = new VMGateTests.FakeConnector();
        await using var gate = new VMGate(connector, "fixture-brand");
        await gate.OpenAsync();
        connector.Sessions[0].Emit(new VMEvent { Stage = "runtime-download", Percent = 41.5, Message = "Downloading" });
        var view = VMScreen.For(gate, Brand, null, "");
        Assert.True(view.ShowProgress);
        Assert.Equal(42, view.ProgressValue);
        Assert.True(Button(view, "CancelSetup").Enabled);
        connector.Sessions[0].Emit(new VMEvent { Stage = "installing", Percent = 60, Message = "" });
        view = VMScreen.For(gate, Brand, null, "");
        Assert.Equal(0, view.ProgressValue);
        Assert.Equal(VMText.Working, Line(view, "VMMessage"));
    }

    [Fact]
    public void ThePrepareHintFollowsTheLegacyOrder()
    {
        Assert.Equal(VMText.ChooseVersion, VMText.PrepareBlockedReason(null, "", "", ""));
        Assert.Equal(VMText.EnterUsername, VMText.PrepareBlockedReason("img", "root", "p", "p"));
        Assert.Equal(VMText.EnterUsername, VMText.PrepareBlockedReason("img", "Upper", "p", "p"));
        Assert.Equal(VMText.SetPassword, VMText.PrepareBlockedReason("img", "linux_user", "", ""));
        Assert.Equal(VMText.PasswordsDiffer, VMText.PrepareBlockedReason("img", "linux_user", "a", "b"));
        Assert.Equal("", VMText.PrepareBlockedReason("img", "linux_user", "a", "a"));
    }
}

// Word for word with the legacy Linux window screens.
public sealed class VMTextTests
{
    private static readonly Branding Brand = new() { ProductName = "@PRODUCT@", Name = "@DISTRO@" };

    private static string Legacy(string file)
    {
        string source = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", file));
        source = Regex.Replace(source, @"['`]\s*\+\s*['`]", "");
        source = Regex.Replace(source, "<[^>]+>", "");
        source = Regex.Replace(source, @"\s+", " ");
        return source.Replace("\\\\", "\\");
    }

    // Code assertions read the source with only whitespace collapsed: the HTML
    // removal above would also cut through comparison operators.
    private static string Code(string file) => Regex.Replace(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", file)), @"\s+", " ");

    private static void Same(string file, string native, params (string Value, string Template)[] names)
    {
        foreach (var (value, template) in names) native = native.Replace(value, template);
        Assert.Contains(native.Replace("@DISTRO@", "${distroName()}"), Legacy(file));
    }

    [Fact]
    public void LinuxWindowLinesMatchTheLegacyScreens()
    {
        foreach (string text in new[] { VMText.BuilderStarting, VMText.CheckingRelease, VMText.PreparingTitle, VMText.Working, VMText.InProgress, VMText.ErrorTitle, VMText.StartingTitle, VMText.StoppedTitle })
            Same("vmpreview.js", text);
        Same("vmpreview.js", VMText.StartingBody("@NAME@", Brand), ("@NAME@", "${escapeText(state.selected?.name || distroName())}"));
        Assert.StartsWith("@DISTRO@ is starting", VMText.StartingBody(null, Brand));
        foreach (string label in new[] { VMText.ShutDown, VMText.ForceStop, VMText.StartAgain, VMText.CancelSetup })
            Assert.Contains($"btn('{label}'", Legacy("vmpreview.js"));
        Assert.Contains($"confirm('{VMText.ForceStopConfirm}')", Legacy("vmpreview.js"));
        Same("launchpad.js", VMText.StartInWindow(Brand));
        Assert.Contains($"btn('{VMText.SetUpRuntime}'", Legacy("launchpad.js"));
        foreach (string hint in new[] { VMText.ChooseVersion, VMText.EnterUsername, VMText.SetPassword, VMText.PasswordsDiffer })
            Assert.Contains($"vmReason = '{hint}'", Code("launchpad.js"));
        Assert.Contains("/^[a-z_][a-z0-9_-]{0,31}$/.test(c.username) || c.username === 'root'", Code("launchpad.js"));
        Same("control.js", VMText.TryTitle);
        Same("control.js", VMText.TryBody(Brand, "@ACC@").Replace("@ACC@", "${String(vm.accelerator || 'hardware acceleration').split(',')[0].toUpperCase()}"));
        Assert.Equal(VMText.TryBody(Brand, "HARDWARE ACCELERATION"), VMText.TryBody(Brand, ""));
        Assert.Contains($"btn('{VMText.BootInVM}'", Legacy("control.js"));
    }
}
