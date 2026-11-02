using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Wootc.Shell.Engine;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

// The engine's recorded install:progress frames
// (app/native_install_progress_test.go) over a real pipe.
public sealed class InstallProgressProtocolTests
{
    private const string Session = "0123456789abcdef0123456789abcdef";

    private static string[] Frames(string name) =>
        File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "Fixtures", "install-progress", name));

    private sealed class Duplex(Stream input, Stream output) : Stream
    {
        public override bool CanRead => true; public override bool CanWrite => true; public override bool CanSeek => false;
        public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override int Read(byte[] buffer, int offset, int count) => input.Read(buffer, offset, count);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default) => input.ReadAsync(buffer, token);
        public override void Write(byte[] buffer, int offset, int count) => output.Write(buffer, offset, count);
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken token = default) => output.WriteAsync(buffer, token);
        public override Task FlushAsync(CancellationToken token) => output.FlushAsync(token);
        public override void Flush() => output.Flush();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
    }

    private sealed class Pair : IDisposable
    {
        public readonly AnonymousPipeServerStream ToEngine = new(PipeDirection.Out), ToShell = new(PipeDirection.Out);
        public readonly AnonymousPipeClientStream EngineReads, ShellReads;
        public readonly Duplex Engine;
        public Pair()
        {
            EngineReads = new(PipeDirection.In, ToEngine.ClientSafePipeHandle);
            ShellReads = new(PipeDirection.In, ToShell.ClientSafePipeHandle);
            Engine = new(EngineReads, ToShell);
        }
        public NativeEngineSession Session(string? install) => new(new Duplex(ShellReads, ToEngine), Process.GetCurrentProcess(), expectedBrand: "wootc", installSession: install);
        public async Task SendAsync(string line, CancellationToken token) { await Engine.WriteAsync(Encoding.UTF8.GetBytes(line + "\n"), token); await Engine.FlushAsync(token); }
        public void Dispose() { ToShell.Dispose(); ToEngine.Dispose(); EngineReads.Dispose(); ShellReads.Dispose(); }
    }

    [Fact]
    public void RecordedEventsDecodeAndForeignShapesAreRefused()
    {
        foreach (string frame in Frames("success.ndjson").Concat(Frames("failure-after-arm.ndjson")))
        {
            using var document = JsonDocument.Parse(frame);
            NativeProtocol.DecodeProgress(document.RootElement.GetProperty("params"));
        }
        string Mutate(Action<JsonObject> change) { var node = JsonNode.Parse(Frames("success.ndjson")[0])!["params"]!.AsObject(); change(node); return node.ToJsonString(); }
        foreach (string refused in new[]
        {
            Mutate(node => node["path"] = "C:\\private"),
            Mutate(node => node.Remove("step")),
            Mutate(node => node.Remove("percent")),
            Mutate(node => node["percent"] = "5"),
            Mutate(node => node["done"] = "false"),
            Mutate(node => node["message"] = new string('x', 4097)),
            Mutate(node => node["error"] = 7),
            Mutate(node => node["warnings"] = "not-an-array"),
            Mutate(node => node["warnings"] = new JsonArray(JsonValue.Create(7))),
            Frames("success.ndjson")[0].Split("\"params\":")[1].TrimEnd('}').Replace("\"done\":false", "\"done\":false,\"done\":true") + "}",
            "[]",
        })
        {
            using var document = JsonDocument.Parse(refused);
            Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeProgress(document.RootElement));
        }
    }

    [Fact]
    public async Task AnInstallSessionDeliversItsProgressInOrder()
    {
        using var pair = new Pair();
        var session = pair.Session(Session);
        var received = new List<ProgressEvent>();
        var all = new TaskCompletionSource();
        string[] frames = Frames("success.ndjson");
        session.ProgressReceived += update => { lock (received) { received.Add(update); if (received.Count == frames.Length) all.TrySetResult(); } };
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        foreach (string frame in frames) await pair.SendAsync(frame, deadline.Token);
        await all.Task.WaitAsync(deadline.Token);
        Assert.Equal(frames.Select(frame => JsonDocument.Parse(frame).RootElement.GetProperty("params").GetProperty("step").GetString()), received.Select(update => update.Step));
        Assert.True(received[^1].Done);
        Assert.Equal("Checking your PC", received[0].PhaseId);
    }

    [Fact]
    public async Task CancelStatusAndRestartUseTheirOwnMethodsWithoutParameters()
    {
        using var pair = new Pair();
        var session = pair.Session(Session);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        async Task Answer(string method, string result)
        {
            using var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(pair.Engine, 4096, deadline.Token));
            Assert.Equal(method, request.RootElement.GetProperty("method").GetString());
            Assert.False(request.RootElement.TryGetProperty("params", out _));
            await pair.SendAsync($"{{\"jsonrpc\":\"2.0\",\"id\":{request.RootElement.GetProperty("id").GetInt64()},\"result\":{result}}}", deadline.Token);
        }
        var cancelling = session.CancelInstallAsync(deadline.Token);
        await Answer("CancelInstall", "null");
        await cancelling;
        var status = session.GetInstallStatusAsync(deadline.Token);
        await Answer("GetStatus", "{\"running\":false,\"done\":false,\"existing\":true}");
        Assert.False((await status).Running);
        var restart = session.RebootAsync(deadline.Token);
        await Answer("Reboot", "null");
        await restart;
        var unexpected = session.RebootAsync(deadline.Token);
        await Answer("Reboot", "{}");
        await Assert.ThrowsAsync<InvalidDataException>(() => unexpected);
        Assert.Equal("rpc-cancel", NativeEngineSession.RpcStage("CancelInstall"));
        Assert.Equal("rpc-restart", NativeEngineSession.RpcStage("Reboot"));
    }

    [Fact]
    public async Task AnAssessmentSessionHasNoInstallActionsAndIgnoresProgress()
    {
        using var pair = new Pair();
        var session = pair.Session(null);
        int received = 0;
        session.ProgressReceived += _ => received++;
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.CancelInstallAsync(CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.RebootAsync(CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.GetInstallStatusAsync(CancellationToken.None));
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        foreach (string frame in Frames("success.ndjson")) await pair.SendAsync(frame, deadline.Token);
        // A later response still arrives: the ignored notifications did not end the session.
        var status = session.CallAsync<InstallStatus>("GetStatus", deadline.Token);
        using var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(pair.Engine, 4096, deadline.Token));
        await pair.SendAsync($"{{\"jsonrpc\":\"2.0\",\"id\":{request.RootElement.GetProperty("id").GetInt64()},\"result\":{{\"running\":false,\"done\":false,\"existing\":false}}}}", deadline.Token);
        await status;
        Assert.Equal(0, received);
    }
}
