using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class InstallGateTests
{
    private const string Brand = "fixture-brand";
    private const string Intent = "0123456789abcdef0123456789abcdef";

    private static InstallConfig Plan() => new() { ImageRef = "ghcr.io/tuna-os/yellowfin:gnome", Username = "linux_user", Password = "public synthetic password", StorageDrive = "D", DiskSizeGB = 40, Encryption = "none", Bootloader = "auto" };

    private sealed class FakeInstallSession : IInstallEngineSession
    {
        public Func<InstallConfig, string, NativeInstallGrant> Grant = (plan, session) => new NativeInstallGrant
        {
            SchemaVersion = 1, Session = session, BrandId = Brand, IntentId = Intent, ImageRef = plan.ImageRef,
            StorageDrive = plan.StorageDrive, DiskSizeGB = plan.DiskSizeGB, Encryption = plan.Encryption,
        };
        public Exception? Refusal, ConfirmFailure;
        public string SessionId = "";
        public readonly List<InstallConfig> Plans = new();
        public readonly List<NativeInstallGrant> Confirmed = new();
        public int Disposed;
        public Task<StartupSnapshot> ReadStartupAsync(CancellationToken token) => throw new InvalidOperationException("An install session has no startup read");
        public Task<NativeInstallGrant> PrepareInstallAsync(InstallConfig plan, CancellationToken token)
        {
            Plans.Add(plan);
            return Refusal is null ? Task.FromResult(Grant(plan, SessionId)) : Task.FromException<NativeInstallGrant>(Refusal);
        }
        public Task ConfirmInstallAsync(NativeInstallGrant grant, CancellationToken token)
        {
            Confirmed.Add(grant);
            return ConfirmFailure is null ? Task.CompletedTask : Task.FromException(ConfirmFailure);
        }
        public ValueTask DisposeAsync() { Disposed++; return ValueTask.CompletedTask; }
    }

    private sealed class FakeConnector : IEngineConnector
    {
        public readonly List<ConnectRequest> Requests = new();
        public readonly List<FakeInstallSession> Sessions = new();
        public ConnectionOutcome Outcome = ConnectionOutcome.Connected;
        public Action<FakeInstallSession>? Configure;
        public Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken token)
        {
            Requests.Add(request);
            if (Outcome != ConnectionOutcome.Connected) return Task.FromResult(new ConnectionAttempt(Outcome, Reason: "Administrator permission was declined. You can retry."));
            var session = new FakeInstallSession { SessionId = request.SessionId };
            Configure?.Invoke(session);
            Sessions.Add(session);
            return Task.FromResult(new ConnectionAttempt(ConnectionOutcome.Connected, session));
        }
    }

    [Fact]
    public async Task OnlyAMatchingEngineGrantEnablesInstall()
    {
        var connector = new FakeConnector();
        await using var gate = new InstallGate(connector, Brand);
        Assert.False(gate.CanInstall);
        await gate.PrepareAsync(Plan());
        var request = Assert.Single(connector.Requests);
        Assert.True(request.Install);
        Assert.Equal(InstallGateState.Granted, gate.State);
        Assert.True(gate.CanInstall);
        Assert.Equal("public synthetic password", Assert.Single(connector.Sessions[0].Plans).Password);
        Assert.Equal(0, connector.Sessions[0].Disposed);
    }

    public static TheoryData<string> Mismatches() => new() { "session", "brand", "intent", "image", "storage", "size", "encryption", "schema" };

    [Theory]
    [MemberData(nameof(Mismatches))]
    public async Task AGrantForAnotherPlanOrSessionIsRefused(string field)
    {
        var connector = new FakeConnector
        {
            Configure = session =>
            {
                var original = session.Grant;
                session.Grant = (plan, id) =>
                {
                    var grant = original(plan, id);
                    switch (field)
                    {
                        case "session": grant.Session = "ffffffffffffffffffffffffffffffff"; break;
                        case "brand": grant.BrandId = "other-brand"; break;
                        case "intent": grant.IntentId = "NOT-HEX"; break;
                        case "image": grant.ImageRef = "ghcr.io/example/other:latest"; break;
                        case "storage": grant.StorageDrive = "E"; break;
                        case "size": grant.DiskSizeGB = 41; break;
                        case "encryption": grant.Encryption = "luks-passphrase"; break;
                        case "schema": grant.SchemaVersion = 2; break;
                    }
                    return grant;
                };
            }
        };
        await using var gate = new InstallGate(connector, Brand);
        await gate.PrepareAsync(Plan());
        Assert.Equal(InstallGateState.Refused, gate.State);
        Assert.False(gate.CanInstall);
        Assert.Equal(1, connector.Sessions[0].Disposed);
    }

    [Fact]
    public async Task EngineRefusalAndDeclinedPermissionKeepInstallDisabled()
    {
        var refused = new FakeConnector { Configure = session => session.Refusal = new InvalidDataException("TPM auto-unlock is not available yet") };
        await using (var gate = new InstallGate(refused, Brand))
        {
            await gate.PrepareAsync(Plan());
            Assert.Equal(InstallGateState.Refused, gate.State);
            Assert.Equal("TPM auto-unlock is not available yet", gate.Reason);
            Assert.False(gate.CanInstall);
            Assert.Equal(1, refused.Sessions[0].Disposed);
            await Assert.ThrowsAsync<InvalidOperationException>(() => gate.ConfirmAsync());
        }
        var declined = new FakeConnector { Outcome = ConnectionOutcome.PermissionDeclined };
        await using (var gate = new InstallGate(declined, Brand))
        {
            await gate.PrepareAsync(Plan());
            Assert.Equal(InstallGateState.Refused, gate.State);
            Assert.Contains("declined", gate.Reason);
            Assert.False(gate.CanInstall);
        }
    }

    [Fact]
    public async Task AChangedPlanDiscardsTheGrantAndItsSession()
    {
        var connector = new FakeConnector();
        await using var gate = new InstallGate(connector, Brand);
        await gate.PrepareAsync(Plan());
        await gate.InvalidateAsync();
        Assert.Equal(InstallGateState.Idle, gate.State);
        Assert.False(gate.CanInstall);
        Assert.Null(gate.Grant);
        Assert.Equal(1, connector.Sessions[0].Disposed);
        await Assert.ThrowsAsync<InvalidOperationException>(() => gate.ConfirmAsync());
        Assert.Empty(connector.Sessions[0].Confirmed);
        // A new plan uses a new session identity and a new elevation.
        await gate.PrepareAsync(Plan());
        Assert.Equal(2, connector.Requests.Count);
        Assert.NotEqual(connector.Requests[0].SessionId, connector.Requests[1].SessionId);
    }

    [Fact]
    public async Task ConfirmingSendsTheGrantOnceAndKeepsAStartedSession()
    {
        var connector = new FakeConnector();
        await using var gate = new InstallGate(connector, Brand);
        await gate.PrepareAsync(Plan());
        var grant = gate.Grant!;
        await gate.ConfirmAsync();
        Assert.Equal(InstallGateState.Started, gate.State);
        Assert.Same(grant, Assert.Single(connector.Sessions[0].Confirmed));
        Assert.False(gate.CanInstall);
        await gate.InvalidateAsync();
        Assert.Equal(InstallGateState.Started, gate.State);
        Assert.Equal(0, connector.Sessions[0].Disposed);
        await Assert.ThrowsAsync<InvalidOperationException>(() => gate.ConfirmAsync());
        Assert.Single(connector.Sessions[0].Confirmed);
    }

    [Fact]
    public async Task AFailedConfirmationNeedsANewPlan()
    {
        var connector = new FakeConnector { Configure = session => session.ConfirmFailure = new InvalidDataException("native install observations changed") };
        await using var gate = new InstallGate(connector, Brand);
        await gate.PrepareAsync(Plan());
        await gate.ConfirmAsync();
        Assert.Equal(InstallGateState.Failed, gate.State);
        Assert.Equal("native install observations changed", gate.Reason);
        Assert.False(gate.CanInstall);
        Assert.Equal(1, connector.Sessions[0].Disposed);
        await Assert.ThrowsAsync<InvalidOperationException>(() => gate.ConfirmAsync());
    }
}
