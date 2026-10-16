using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

// The engine's recorded VM responses and vm:progress stream
// (app/native_vm_test.go) through the shell's strict decoders, and the
// request frames the shell sends over a real pipe. No VM runs.
public sealed class VMProtocolTests
{
    private const string Session = "0123456789abcdef0123456789abcdef";

    private static string[] Lines(string name) => File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "Fixtures", "native-vm", name));

    private static (string Method, JsonObject Result)[] Responses() => Lines("responses.ndjson")
        .Select(line => JsonNode.Parse(line)!.AsObject())
        .Select(node => (node["method"]!.GetValue<string>(), node["response"]!["result"]!.AsObject())).ToArray();

    private static T Decode<T>(string method, JsonNode result, string brand = "wootc")
    {
        using var document = JsonDocument.Parse(result.ToJsonString());
        return NativeProtocol.DecodeResult<T>(method, document.RootElement, brand);
    }

    private static JsonObject Mutated(JsonObject original, Action<JsonObject> change)
    {
        var copy = JsonNode.Parse(original.ToJsonString())!.AsObject();
        change(copy);
        return copy;
    }

    [Fact]
    public void RecordedFramesDecode()
    {
        var responses = Responses();
        Assert.Equal(["GetNativeVMStatus", "GetNativeVMStatus", "GetNativeVMStatus", "PrepareNativeVMAction"], responses.Select(frame => frame.Method));
        var absent = Decode<NativeVMStatus>("GetNativeVMStatus", responses[0].Result);
        Assert.Equal("absent", absent.Phase);
        Assert.True(absent.Prepare.RuntimeNeeded);
        var stopped = Decode<NativeVMStatus>("GetNativeVMStatus", responses[1].Result);
        Assert.True(stopped.Launch.Available);
        Assert.Equal("whpx", stopped.Launch.Accelerator);
        Assert.Equal("running", Decode<NativeVMStatus>("GetNativeVMStatus", responses[2].Result).Phase);
        var grant = Decode<NativeVMGrant>("PrepareNativeVMAction", responses[3].Result);
        Assert.Equal(VMActions.Prepare, grant.Action);
        Assert.Equal("linux_user", grant.Username);
        var stages = Lines("progress.ndjson").Select(line =>
        {
            using var document = JsonDocument.Parse(line);
            Assert.Equal("vm:progress", document.RootElement.GetProperty("method").GetString());
            return NativeProtocol.DecodeVMProgress(document.RootElement.GetProperty("params")).Stage;
        });
        Assert.Equal(["pulling", "pulling", "installing", "finalizing", "started", "stopped"], stages);
    }

    [Fact]
    public void ForeignShapesAreRefused()
    {
        var responses = Responses();
        var status = responses[1].Result; var grant = responses[3].Result;
        foreach (var refused in new[]
        {
            Mutated(status, node => node["diskPath"] = @"C:\wootc\disks\root.disk"), Mutated(status, node => node["pid"] = 4242),
            Mutated(status, node => node["phase"] = "hibernating"), Mutated(status, node => node["schemaVersion"] = 2),
            Mutated(status, node => node["launch"]!["qemuPath"] = @"C:\wootc\qemu\qemu-system-x86_64.exe"), Mutated(status, node => node.Remove("prepare")),
            Mutated(status, node => node["desktopReady"] = "true"), Mutated(status, node => node["error"] = new string('x', 4097)),
        })
            Assert.Throws<InvalidDataException>(() => Decode<NativeVMStatus>("GetNativeVMStatus", refused));
        foreach (var refused in new[]
        {
            Mutated(grant, node => node["password"] = "public synthetic password"), Mutated(grant, node => node["action"] = "delete-disk"),
            Mutated(grant, node => node["intentId"] = "short"), Mutated(grant, node => node["brandId"] = "bazzite"), Mutated(grant, node => node.Remove("phase")),
        })
            Assert.Throws<InvalidDataException>(() => Decode<NativeVMGrant>("PrepareNativeVMAction", refused));
        string progress = JsonNode.Parse(Lines("progress.ndjson")[0])!["params"]!.ToJsonString();
        foreach (string refused in new[]
        {
            progress.Replace("\"pulling\"", "\"Pulling <b>\""), progress.Replace("\"percent\":0", "\"percent\":\"0\""),
            progress.Replace("}", ",\"path\":\"C:\\\\x\"}"), progress.Replace("\"stage\":\"pulling\",", ""),
        })
        {
            using var document = JsonDocument.Parse(refused);
            Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeVMProgress(document.RootElement));
        }
        using var notNull = JsonDocument.Parse("{}");
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeResult<object?>("ConfirmNativeVMAction", notNull.RootElement, "wootc"));
    }

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

    [Fact]
    public async Task TheShellSendsOnlyThePlanAndTheIntentAndReceivesProgressInOrder()
    {
        using var toEngine = new AnonymousPipeServerStream(PipeDirection.Out);
        using var toShell = new AnonymousPipeServerStream(PipeDirection.Out);
        using var engineReads = new AnonymousPipeClientStream(PipeDirection.In, toEngine.ClientSafePipeHandle);
        using var shellReads = new AnonymousPipeClientStream(PipeDirection.In, toShell.ClientSafePipeHandle);
        var engine = new Duplex(engineReads, toShell);
        var session = new NativeEngineSession(new Duplex(shellReads, toEngine), Process.GetCurrentProcess(), expectedBrand: "wootc", installSession: Session);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        async Task Send(string line) { await engine.WriteAsync(Encoding.UTF8.GetBytes(line + "\n"), deadline.Token); await engine.FlushAsync(deadline.Token); }
        async Task<JsonElement?> Answer(string method, string result)
        {
            using var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(engine, 4096, deadline.Token));
            Assert.Equal(method, request.RootElement.GetProperty("method").GetString());
            JsonElement? parameters = request.RootElement.TryGetProperty("params", out var value) ? value.Clone() : null;
            await Send($"{{\"jsonrpc\":\"2.0\",\"id\":{request.RootElement.GetProperty("id").GetInt64()},\"result\":{result}}}");
            return parameters;
        }
        var responses = Responses();
        var reading = session.ReadVMStatusAsync(deadline.Token);
        Assert.Null(await Answer("GetNativeVMStatus", responses[0].Result.ToJsonString()));
        Assert.Equal("absent", (await reading).Phase);
        var preparing = session.PrepareVMActionAsync(new NativeVMPlan { Action = VMActions.Prepare, ImageRef = "ghcr.io/tuna-os/yellowfin:gnome", Username = "linux_user", Password = "public synthetic password" }, deadline.Token);
        var plan = await Answer("PrepareNativeVMAction", responses[3].Result.ToJsonString());
        Assert.Equal(["action", "imageRef", "username", "password"], plan!.Value.EnumerateObject().Select(property => property.Name));
        var grant = await preparing;
        var received = new List<string>();
        var all = new TaskCompletionSource();
        string[] progress = Lines("progress.ndjson");
        session.VMProgressReceived += update => { lock (received) { received.Add(update.Stage); if (received.Count == progress.Length) all.TrySetResult(); } };
        var confirming = session.ConfirmVMActionAsync(grant, deadline.Token);
        var consent = await Answer("ConfirmNativeVMAction", "null");
        Assert.Equal(["kind", "protocolVersion", "session", "brandId", "intentId", "action"], consent!.Value.EnumerateObject().Select(property => property.Name));
        Assert.Equal("confirm-vm", consent.Value.GetProperty("kind").GetString());
        await confirming;
        foreach (string line in progress) await Send(line);
        await all.Task.WaitAsync(deadline.Token);
        Assert.Equal(["pulling", "pulling", "installing", "finalizing", "started", "stopped"], received);
        var stopping = session.PrepareVMActionAsync(new NativeVMPlan { Action = VMActions.Stop, Password = "ignored" }, deadline.Token);
        var stopPlan = await Answer("PrepareNativeVMAction", Mutated(responses[3].Result, node => { node["action"] = "stop"; node["phase"] = "running"; }).ToJsonString());
        Assert.Equal(["action"], stopPlan!.Value.EnumerateObject().Select(property => property.Name));
        Assert.Equal(VMActions.Stop, (await stopping).Action);
        Assert.Equal("rpc-vm-plan", NativeEngineSession.RpcStage("PrepareNativeVMAction"));
        Assert.Equal("rpc-vm-consent", NativeEngineSession.RpcStage("ConfirmNativeVMAction"));
        Assert.Equal("rpc-vm-status", NativeEngineSession.RpcStage("GetNativeVMStatus"));
    }

    [Fact]
    public async Task AnAssessmentSessionHasNoVMActions()
    {
        using var toEngine = new AnonymousPipeServerStream(PipeDirection.Out);
        using var toShell = new AnonymousPipeServerStream(PipeDirection.Out);
        using var shellReads = new AnonymousPipeClientStream(PipeDirection.In, toShell.ClientSafePipeHandle);
        IVMEngineSession session = new NativeEngineSession(new Duplex(shellReads, toEngine), Process.GetCurrentProcess(), expectedBrand: "wootc");
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ReadVMStatusAsync(CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.PrepareVMActionAsync(new NativeVMPlan { Action = VMActions.Boot }, CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ConfirmVMActionAsync(new NativeVMGrant { Session = Session }, CancellationToken.None));
    }
}
