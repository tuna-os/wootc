using System.Text;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text.Json;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

public sealed class StartupProgressTests
{
    private static NativeProtocol.Handshake Hello() => new() { Kind="hello", ProtocolVersion=1, Session=new string('a',32), BuildId=new string('b',40), BrandId="wootc" };
    private static byte[] Frame(NativeProtocol.Handshake hello,string phase,string outcome) => JsonSerializer.SerializeToUtf8Bytes(new { kind="startup",protocolVersion=1,session=hello.Session,buildId=hello.BuildId,brandId=hello.BrandId,phase,outcome });
    [Fact]
    public void ReadyRequiresEveryOrderedObservedPhase()
    {
        var hello=Hello(); var progress=new NativeProtocol.StartupProgress();
        byte[] ready=JsonSerializer.SerializeToUtf8Bytes(new NativeProtocol.Handshake {Kind="ready",ProtocolVersion=1,Session=hello.Session,BuildId=hello.BuildId,BrandId=hello.BrandId});
        Assert.Throws<InvalidDataException>(()=>progress.Accept(ready,hello));
        foreach(string phase in new[]{"selection","application","dispatcher"}) foreach(string outcome in new[]{"begin","complete"}) Assert.False(progress.Accept(Frame(hello,phase,outcome),hello));
        Assert.True(progress.Accept(ready,hello));
    }
    [Fact]
    public void DuplicateOutOfOrderForeignAndExcessProgressRefuse()
    {
        var hello=Hello(); byte[] first=Frame(hello,"selection","begin");
        var progress=new NativeProtocol.StartupProgress(); Assert.False(progress.Accept(first,hello));
        Assert.Throws<InvalidDataException>(()=>progress.Accept(first,hello));
        Assert.Throws<InvalidDataException>(()=>new NativeProtocol.StartupProgress().Accept(Frame(hello,"dispatcher","begin"),hello));
        var foreign=Hello(); foreign.Session=new string('c',32);
        Assert.Throws<InvalidDataException>(()=>new NativeProtocol.StartupProgress().Accept(Frame(foreign,"selection","begin"),hello));
        string duplicate="{\"phase\":\"selection\","+Encoding.UTF8.GetString(first)[1..];
        Assert.Throws<InvalidDataException>(()=>new NativeProtocol.StartupProgress().Accept(Encoding.UTF8.GetBytes(duplicate),hello));
        var complete=new NativeProtocol.StartupProgress(); foreach(string phase in new[]{"selection","application","dispatcher"}) foreach(string outcome in new[]{"begin","complete"}) complete.Accept(Frame(hello,phase,outcome),hello);
        Assert.Throws<InvalidDataException>(()=>complete.Accept(first,hello));
    }
    [Fact]
    public void MalformedProgressNeverProjectsRawInput()
    {
        const string publicSecret = "111111-111111-111111-111111-111111-111111-111111-111111";
        var error = Assert.Throws<InvalidDataException>(() => new NativeProtocol.StartupProgress().Accept(Encoding.UTF8.GetBytes("{\"kind\":" + publicSecret), Hello()));
        Assert.DoesNotContain(publicSecret, error.Message);
        Assert.Equal("Invalid engine startup frame", error.Message);
    }
    [Fact]
    public void FailedSourcePhaseSurvivesLatestCleanupProjection()
    {
        var hello=Hello();var progress=new NativeProtocol.StartupProgress();progress.Accept(Frame(hello,"selection","begin"),hello);
        var error=Assert.Throws<IOException>(()=>progress.Accept(Frame(hello,"selection","failed"),hello));
        var diagnostic=new NativeDiagnosticState();diagnostic.Project(progress.LastPhase,error,null);
        string latest=diagnostic.Project("cleanup-exited",null,null);
        Assert.Contains("PrimaryStartup:startup-selection; Failure:io",latest);
    }
    [Fact]
    public async Task ActualPipeBlockedStartupNeverReadyAndRetainsPhaseAfterOwnedExit()
    {
        string name = "wootc-startup-test-" + Guid.NewGuid().ToString("N");
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
        using var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var accepting = server.WaitForConnectionAsync(deadline.Token); await client.ConnectAsync(deadline.Token); await accepting;
        using var owned = Process.Start(new ProcessStartInfo("cmd.exe", "/c pause") { UseShellExecute=false,RedirectStandardInput=true,RedirectStandardOutput=true,CreateNoWindow=true })!;
        var projector = new NativeDiagnosticState(); string latest=""; string stage="hello-ready";
        var phaseObserved = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            using var requestDeadline = new CancellationTokenSource();
            var reading = NativeProtocol.ReadStartupAsync(client,Hello(), phase => { stage=phase; latest=projector.Project(stage,null,owned); phaseObserved.TrySetResult(); },requestDeadline.Token);
            byte[] frame=Frame(Hello(),"selection","begin"); await server.WriteAsync(frame,deadline.Token);await server.WriteAsync(new byte[]{(byte)'\n'},deadline.Token);await server.FlushAsync(deadline.Token);
            await phaseObserved.Task.WaitAsync(deadline.Token);
            Assert.Equal("startup-selection",stage);
            Assert.False(reading.IsCompleted);
            requestDeadline.Cancel(); var failure=await Assert.ThrowsAnyAsync<OperationCanceledException>(()=>reading);
            latest=projector.Project(stage,failure,owned);
        }
        finally
        {
            owned.StandardInput.Close();await owned.WaitForExitAsync(deadline.Token);
            latest=projector.Project("cleanup-exited",null,owned);
            Assert.Contains("Stage:cleanup-exited",latest);
            Assert.Contains($"Engine:exited:{owned.ExitCode}",latest);
            Assert.Contains("PrimaryStartup:startup-selection; Failure:deadline",latest);
        }
    }
}
