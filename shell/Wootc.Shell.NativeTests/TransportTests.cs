using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Security.Principal;
using Wootc.Shell.Native;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.NativeTests;

public sealed class TransportTests
{
    [Fact]
    public async Task MockedConsentRefusalIsDistinctAndRetryHasFreshContext()
    {
        string engine = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PublicNativeFixture", "wootc-engine.exe");
        var request = RunasLaunch.Create(engine, Guid.NewGuid().ToString("N"), Environment.ProcessId);
        Assert.True(request.UseShellExecute);
        Assert.Equal("runas", request.Verb);
        Assert.Equal("--source-pid", request.ArgumentList[3]);
        var declined = await RunasLaunch.StartAsync(request, _ => throw new Win32Exception(1223));
        Assert.True(declined.Declined); Assert.Null(declined.Process);
        var retry = RunasLaunch.Create(engine, Guid.NewGuid().ToString("N"), Environment.ProcessId);
        Assert.NotEqual(request.ArgumentList[2], retry.ArgumentList[2]);
        await Assert.ThrowsAsync<Win32Exception>(() => RunasLaunch.StartAsync(retry, _ => throw new Win32Exception(5)));
        Assert.Throws<InvalidDataException>(() => RunasLaunch.Create(engine, "self-asserted", 1));
    }

    [Fact]
    public async Task ActualLocalPipeServerMatchesRetainedProcessTokenAndSession()
    {
        string name = "wootc-native-test-" + Guid.NewGuid().ToString("N");
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var accepting = server.WaitForConnectionAsync(deadline.Token);
        await client.ConnectAsync(deadline.Token); await accepting;
        using var retained = Process.GetCurrentProcess();
        var observed = WindowsPeer.Observe(retained);
        using var user = WindowsIdentity.GetCurrent();
        Assert.Equal(user.User?.Value, observed.UserSid);
        Assert.True(observed.Elevated); // Hosted Windows service token; not interactive UAC proof.
        WindowsPeer.VerifyPipeServer(client.SafePipeHandle, retained, observed, observed.ImagePath);
        Assert.Throws<InvalidDataException>(() => WindowsPeer.VerifyPipeServer(client.SafePipeHandle, retained, observed with { UserSid = "S-1-5-7" }, observed.ImagePath));
        Assert.Throws<InvalidDataException>(() => WindowsPeer.VerifyPipeServer(client.SafePipeHandle, retained, observed with { SessionId = observed.SessionId + 1 }, observed.ImagePath));
        Assert.Throws<InvalidDataException>(() => WindowsPeer.VerifyPipeServer(client.SafePipeHandle, retained, observed, Path.Combine(Path.GetDirectoryName(observed.ImagePath)!, "foreign.exe")));
        using var other = Process.Start(new ProcessStartInfo("cmd.exe", "/c pause") { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, CreateNoWindow = true })!;
        _ = other.Handle;
        try { Assert.Throws<InvalidDataException>(() => WindowsPeer.VerifyPipeServer(client.SafePipeHandle, other, observed, observed.ImagePath)); }
        finally { other.StandardInput.Close(); if (!other.WaitForExit(2000)) { other.Kill(); other.WaitForExit(2000); } }
    }

    [Fact]
    public async Task ObservedOwnedProcessExitAllowsPendingCleanupAndNewSession()
    {
        using var owned = Process.Start(new ProcessStartInfo("cmd.exe", "/c pause") { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, CreateNoWindow = true })!;
        _ = owned.Handle;
        var connector = new CleanupConnector(new NativeEngineSession(Stream.Null, owned, TimeSpan.FromMilliseconds(100)));
        var controller = new StartupController(new Branding { ProductName = "Public fixture", Name = "Public fixture" }, connector);
        try
        {
            await controller.RequestPermissionAsync();
            Assert.Equal(ConnectionState.DisconnectPending, controller.Connection);
            Assert.False(controller.CanRequestPermission);
            Assert.False(owned.HasExited);
            await controller.RequestPermissionAsync();
            Assert.Equal(1, connector.Calls);
            Assert.Equal(ConnectionState.DisconnectPending, controller.Connection);
            owned.StandardInput.Close();
            using var exitDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await owned.WaitForExitAsync(exitDeadline.Token);
            // Disposal succeeds only after the retained process has been observed exiting.
            await controller.DisposeAsync();
            Assert.Equal(ConnectionState.Offline, controller.Connection);
            Assert.True(controller.CanRequestPermission);
            await controller.RequestPermissionAsync();
            Assert.Equal(2, connector.Calls);
            Assert.Equal(ConnectionState.Ready, controller.Connection);
            await controller.DisposeAsync();
        }
        finally
        {
            // This is only our test-owned cmd.exe handle, never an installer PID scan.
            try { if (!owned.HasExited) { owned.StandardInput.Close(); if (!owned.WaitForExit(2000)) { owned.Kill(); owned.WaitForExit(2000); } } }
            catch (InvalidOperationException) { } // Native session already disposed its retained handle after exit.
        }
    }

    private sealed class CleanupConnector(IEngineSession first) : IEngineConnector
    {
        public int Calls { get; private set; }
        public Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken token) =>
            Task.FromResult(new ConnectionAttempt(ConnectionOutcome.Connected, ++Calls == 1 ? first : new FreshSession()));
    }
    private sealed class FreshSession : IEngineSession
    {
        public Task<StartupSnapshot> ReadStartupAsync(CancellationToken token) => Task.FromResult(new StartupSnapshot(new InstallStatus(), null));
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }

    [Theory]
    [InlineData("{}", "decode")]
    [InlineData("{\"running\":false}", "decode")]
    [InlineData("{\"running\":false,\"done\":false,\"existing\":false,\"existing\":true}", "response")]
    public async Task ActualFramedMissingOrAmbiguousStatusCannotSelectFreshRoute(string result, string failureStage)
    {
        string expectedPrimary = $"PrimaryRpc:rpc-status-{failureStage}; Failure:protocol";
        string name = "wootc-native-response-" + Guid.NewGuid().ToString("N");
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var accepting = server.WaitForConnectionAsync(deadline.Token);
        await client.ConnectAsync(deadline.Token); await accepting;
        using var owned = Process.Start(new ProcessStartInfo("cmd.exe", "/c pause") { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, CreateNoWindow = true })!;
        var observations = new List<string>();
        var projector = new NativeDiagnosticState();
        string latest = "";
        var session = new NativeEngineSession(client, owned, (stage, error) =>
        {
            observations.Add($"{stage}; {NativeEngineConnector.DescribeFailure(error)}");
            latest = projector.Project(stage, error, owned); // Same single latest consumer as UI HelpText.
        });
        try
        {
            var startup = session.ReadStartupAsync(deadline.Token);
            using var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(server, 4096, deadline.Token));
            Assert.Equal("GetStatus", request.RootElement.GetProperty("method").GetString());
            long id = request.RootElement.GetProperty("id").GetInt64();
            await server.WriteAsync(Encoding.UTF8.GetBytes($"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"result\":{result}}}\n"), deadline.Token);
            await server.FlushAsync(deadline.Token);
            await Assert.ThrowsAsync<InvalidDataException>(() => startup);
            Assert.Contains(observations, value => value.StartsWith($"rpc-status-{failureStage}; Failure:protocol", StringComparison.Ordinal));
            // No StartupSnapshot exists, so default false fields cannot route to Assessment.
        }
        finally
        {
            owned.StandardInput.Close();
            await owned.WaitForExitAsync(deadline.Token);
            int exitCode = owned.ExitCode;
            await session.DisposeAsync();
            Assert.Contains(observations, value => value.StartsWith("session-cleanup-exited; Failure:none", StringComparison.Ordinal));
            Assert.Contains("Stage:session-cleanup-exited", latest);
            Assert.Contains($"Engine:exited:{exitCode}", latest);
            Assert.Contains(expectedPrimary, latest);
        }
    }

    [Fact]
    public async Task ActualPipeReplyDeadlineRetainsMethodAndCleanupExitObservations()
    {
        const string expectedPrimary = "PrimaryRpc:rpc-status-response; Failure:deadline";
        string name = "wootc-native-deadline-" + Guid.NewGuid().ToString("N");
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        using var fixtureDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var accepting = server.WaitForConnectionAsync(fixtureDeadline.Token);
        await client.ConnectAsync(fixtureDeadline.Token); await accepting;
        using var owned = Process.Start(new ProcessStartInfo("cmd.exe", "/c pause") { UseShellExecute = false, RedirectStandardInput = true, RedirectStandardOutput = true, CreateNoWindow = true })!;
        var observations = new List<string>();
        var projector = new NativeDiagnosticState();
        string latest = "";
        var session = new NativeEngineSession(client, owned, (stage, error) =>
        {
            observations.Add($"{stage}; {NativeEngineConnector.DescribeFailure(error)}");
            latest = projector.Project(stage, error, owned); // Same single latest consumer as UI HelpText.
        });
        try
        {
            using var requestDeadline = new CancellationTokenSource();
            var requestTask = session.CallAsync<InstallStatus>("GetStatus", requestDeadline.Token);
            using var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(server, 4096, fixtureDeadline.Token));
            Assert.Equal("GetStatus", request.RootElement.GetProperty("method").GetString());
            // The real request crossed the pipe. No response is supplied.
            requestDeadline.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => requestTask);
            Assert.Contains(observations, value => value.StartsWith("rpc-status-response; Failure:deadline", StringComparison.Ordinal));
            Assert.DoesNotContain(observations, value => value.StartsWith("rpc-status-complete", StringComparison.Ordinal));
        }
        finally
        {
            owned.StandardInput.Close();
            await owned.WaitForExitAsync(fixtureDeadline.Token);
            int exitCode = owned.ExitCode;
            await session.DisposeAsync();
            Assert.Contains(observations, value => value.StartsWith("session-cleanup-exited; Failure:none", StringComparison.Ordinal));
            Assert.Contains("Stage:session-cleanup-exited", latest);
            Assert.Contains($"Engine:exited:{exitCode}", latest);
            Assert.Contains(expectedPrimary, latest);
        }
    }

    [Fact]
    public async Task FrameLimitAndDisconnectAreActualStreamOutcomes()
    {
        using var valid = new MemoryStream(System.Text.Encoding.UTF8.GetBytes("hello\nnext\n"));
        Assert.Equal("hello", System.Text.Encoding.UTF8.GetString(await NativeEngineSession.ReadLineAsync(valid, 16, default)));
        Assert.Equal("next", System.Text.Encoding.UTF8.GetString(await NativeEngineSession.ReadLineAsync(valid, 16, default)));
        using var oversized = new MemoryStream(new byte[17]);
        await Assert.ThrowsAsync<InvalidDataException>(() => NativeEngineSession.ReadLineAsync(oversized, 16, default));
        using var ended = new MemoryStream();
        await Assert.ThrowsAsync<EndOfStreamException>(() => NativeEngineSession.ReadLineAsync(ended, 16, default));
    }

    [Theory]
    [InlineData("GetNativeConfiguration",true)]
    [InlineData("GetStatus",false)]
    public async Task ActualMatchingPipeStorageFailureSurvivesOwnedCleanup(string method,bool diagnosticExpected)
    {
        string name="wootc-storage-diagnostic-"+Guid.NewGuid().ToString("N");
        using var server=new NamedPipeServerStream(name,PipeDirection.InOut,1,PipeTransmissionMode.Byte,PipeOptions.Asynchronous);
        using var client=new NamedPipeClientStream(".",name,PipeDirection.InOut,PipeOptions.Asynchronous);
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var accepting=server.WaitForConnectionAsync(deadline.Token);
        await client.ConnectAsync(deadline.Token); await accepting;
        using var owned=Process.Start(new ProcessStartInfo("cmd.exe","/c pause") {UseShellExecute=false,RedirectStandardInput=true,RedirectStandardOutput=true,CreateNoWindow=true})!;
        var projector=new NativeDiagnosticState(); string latest="";
        var session=new NativeEngineSession(client,owned,(stage,error)=>latest=projector.Project(stage,error,owned));
        try
        {
            var call=session.CallAsync<InstallStatus>(method,deadline.Token);
            using var request=JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(server,4096,deadline.Token));
            long id=request.RootElement.GetProperty("id").GetInt64();
            Assert.Equal(method,request.RootElement.GetProperty("method").GetString());
            string reply=$"{{\"jsonrpc\":\"2.0\",\"id\":{id},\"error\":{{\"code\":-32603,\"message\":\"generic failure\",\"data\":{DiagnosticTests.StorageDiagnostic}}}}}}\n";
            await server.WriteAsync(Encoding.UTF8.GetBytes(reply),deadline.Token);await server.FlushAsync(deadline.Token);
            if (diagnosticExpected) await Assert.ThrowsAsync<StorageObservationFailure>(()=>call);
            else await Assert.ThrowsAsync<InvalidDataException>(()=>call);
        }
        finally
        {
            owned.StandardInput.Close();await owned.WaitForExitAsync(deadline.Token);
            await session.DisposeAsync();
            Assert.Contains("Stage:session-cleanup-exited",latest);
            Assert.Contains("PrimaryRpc:",latest);
            if(diagnosticExpected)Assert.Contains("StoragePhase:import-storage",latest);
            else Assert.DoesNotContain("StoragePhase:",latest);
        }
    }
}
