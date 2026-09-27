using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class StartupTests
{
    private static Branding Brand => new() { ProductName = "Bluefin Installer", Name = "Bluefin" };

    [Fact]
    public async Task RefusalPreservesBrandAndAssessmentAndRetryUsesFreshSession()
    {
        var connector = new FakeConnector { Result = new(ConnectionOutcome.PermissionDeclined) };
        await using var controller = new StartupController(Brand, connector);
        Assert.Equal("Bluefin Installer", controller.Brand.ProductName);
        Assert.True(controller.CanRequestPermission);
        await controller.RequestPermissionAsync();
        Assert.Equal(ConnectionState.PermissionDeclined, controller.Connection);
        Assert.Equal(StartupRoute.Assessment, controller.Route);
        Assert.True(controller.CanRequestPermission);
        string priorSession = Assert.Single(connector.Requests).SessionId;
        connector.Result = new(ConnectionOutcome.Connected, new FakeSession(new(new InstallStatus { Existing = true }, null)));
        await controller.RequestPermissionAsync();
        Assert.Equal(StartupRoute.Manage, controller.Route);
        Assert.Equal(ConnectionState.Ready, controller.Connection);
        Assert.NotEqual(priorSession, connector.Requests.Last().SessionId);
        await controller.RequestPermissionAsync();
        Assert.Equal(2, connector.Requests.Count);
    }

    [Theory]
    [InlineData("failed")]
    [InlineData("interrupted")]
    [InlineData("one-shot-never-booted")]
    public void ObservedFailureRoutesToRecovery(string verdict) =>
        Assert.Equal(StartupRoute.Recovery, StartupController.SelectRoute(new(new InstallStatus(), new RecoveryVerdict { Verdict = verdict })));

    [Fact]
    public void ActiveWorkTakesPriorityOverPastFailure() =>
        Assert.Equal(StartupRoute.Progress, StartupController.SelectRoute(new(new InstallStatus { Running = true }, new RecoveryVerdict { Verdict = "failed" })));

    [Fact]
    public void DoneAloneNeverAssertsAnExistingInstallation() =>
        Assert.Equal(StartupRoute.Assessment, StartupController.SelectRoute(new(new InstallStatus { Done = true }, null)));

    [Fact]
    public void UnknownVerdictCannotSelectAGuessedRoute() =>
        Assert.Throws<InvalidDataException>(() => StartupController.SelectRoute(new(new InstallStatus(), new RecoveryVerdict { Verdict = "future-value" })));

    [Fact]
    public async Task InvalidStartupDisposesAuthenticatedSessionAndRetainsRetry()
    {
        var session = new FakeSession(new(new InstallStatus(), new RecoveryVerdict { Verdict = "future-value" }));
        await using var controller = new StartupController(Brand, new FakeConnector { Result = new(ConnectionOutcome.Connected, session) });
        await controller.RequestPermissionAsync();
        Assert.True(session.Disposed);
        Assert.Equal(ConnectionState.Unavailable, controller.Connection);
        Assert.True(controller.CanRequestPermission);
    }

    [Fact]
    public async Task ConcurrentClicksLaunchOnePermissionRequest()
    {
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var result = new TaskCompletionSource<ConnectionAttempt>(TaskCreationOptions.RunContinuationsAsynchronously);
        var connector = new FakeConnector { Connect = async token => { started.SetResult(); return await result.Task.WaitAsync(token); } };
        await using var controller = new StartupController(Brand, connector);
        var first = controller.RequestPermissionAsync();
        await started.Task;
        await controller.RequestPermissionAsync();
        Assert.Single(connector.Requests);
        Assert.False(controller.CanRequestPermission);
        result.SetResult(new(ConnectionOutcome.PermissionDeclined));
        await first;
        Assert.True(controller.CanRequestPermission);
    }

    [Fact]
    public async Task CancelledConnectionKeepsAssessmentAndAllowsANewRequest()
    {
        var connector = new FakeConnector { Connect = async token => { await Task.Delay(Timeout.Infinite, token); return new(ConnectionOutcome.Unavailable); } };
        await using var controller = new StartupController(Brand, connector);
        using var cancellation = new CancellationTokenSource();
        var pending = controller.RequestPermissionAsync(cancellation.Token);
        cancellation.Cancel();
        await pending;
        Assert.Equal(ConnectionState.Offline, controller.Connection);
        Assert.Equal(StartupRoute.Assessment, controller.Route);
        Assert.True(controller.CanRequestPermission);
    }

    private sealed class FakeConnector : IEngineConnector
    {
        public ConnectionAttempt Result { get; set; } = new(ConnectionOutcome.Unavailable);
        public Func<CancellationToken, Task<ConnectionAttempt>>? Connect { get; init; }
        public List<ConnectRequest> Requests { get; } = [];
        public Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken cancellationToken)
        {
            Requests.Add(request);
            return Connect is null ? Task.FromResult(Result) : Connect(cancellationToken);
        }
    }
    private sealed class FakeSession(StartupSnapshot snapshot) : IEngineSession
    {
        public bool Disposed { get; private set; }
        public Task<StartupSnapshot> ReadStartupAsync(CancellationToken cancellationToken) => Task.FromResult(snapshot);
        public ValueTask DisposeAsync() { Disposed = true; return ValueTask.CompletedTask; }
    }
}
