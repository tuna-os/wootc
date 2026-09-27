using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Principal;
using Wootc.Shell.Native;
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
}
