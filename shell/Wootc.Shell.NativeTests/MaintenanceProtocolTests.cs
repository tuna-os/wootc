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

// The engine's recorded maintenance responses
// (app/native_maintenance_test.go) through the shell's strict decoders, and
// the request frames the shell sends for them over a real pipe.
public sealed class MaintenanceProtocolTests
{
    private const string Session = "0123456789abcdef0123456789abcdef";

    private static (string Method, JsonObject Result)[] Recorded() =>
        File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "Fixtures", "native-maintenance", "responses.ndjson"))
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
    public void RecordedResponsesDecode()
    {
        var recorded = Recorded();
        Assert.Equal(["GetUninstallInfo", "GetUninstallInfo", "InspectBoot", "PrepareNativeMaintenance"], recorded.Select(frame => frame.Method));
        var info = Decode<UninstallInfo>("GetUninstallInfo", recorded[0].Result);
        Assert.Equal(@"D:\wootc\disks\root.disk", info.DiskPath);
        Assert.True(info.Deployed);
        Assert.True(Decode<UninstallInfo>("GetUninstallInfo", recorded[1].Result).Orphaned);
        var boot = Decode<BootRepairReport>("InspectBoot", recorded[2].Result);
        Assert.Equal("wootc-listed", boot.BootState);
        Assert.True(boot.CanRepairBoot);
        var grant = Decode<NativeMaintenanceGrant>("PrepareNativeMaintenance", recorded[3].Result);
        Assert.Equal(MaintenanceActions.Uninstall, grant.Action);
        Assert.True(grant.DeleteRootDisk && grant.RemovePartition);
        Assert.Equal("wootc-data", grant.VolumeLabel);
    }

    [Fact]
    public void ForeignShapesAreRefused()
    {
        var recorded = Recorded();
        var info = recorded[0].Result; var boot = recorded[2].Result; var grant = recorded[3].Result;
        foreach (var refused in new[]
        {
            Mutated(info, node => node["rootDiskKey"] = "secret"), Mutated(info, node => node.Remove("deployed")), Mutated(info, node => node["found"] = "true"),
            Mutated(info, node => node["storageDrive"] = "DD"), Mutated(info, node => node["diskSizeGB"] = -1), Mutated(info, node => node["diskPath"] = new string('x', 1025)),
        })
            Assert.Throws<InvalidDataException>(() => Decode<UninstallInfo>("GetUninstallInfo", refused));
        foreach (var refused in new[]
        {
            Mutated(boot, node => node["bootState"] = "linux-default"), Mutated(boot, node => node["recommended"] = "format"), Mutated(boot, node => node["findings"] = "one"),
            Mutated(boot, node => node["refusals"] = new JsonArray(7)), Mutated(boot, node => node.Remove("canRepairBoot")), Mutated(boot, node => node["evidence"] = "raw"),
            Mutated(boot, node => node["findings"] = new JsonArray(Enumerable.Range(0, 65).Select(_ => (JsonNode?)JsonValue.Create("x")).ToArray())),
        })
            Assert.Throws<InvalidDataException>(() => Decode<BootRepairReport>("InspectBoot", refused));
        foreach (var refused in new[]
        {
            Mutated(grant, node => node["action"] = "format-disk"), Mutated(grant, node => node["intentId"] = "short"), Mutated(grant, node => node["schemaVersion"] = 2),
            Mutated(grant, node => node["brandId"] = "bazzite"), Mutated(grant, node => node.Remove("bootState")), Mutated(grant, node => node["password"] = "x"),
            Mutated(grant, node => { node["action"] = "repair-boot"; }), Mutated(grant, node => node["storageDrive"] = "d"),
        })
            Assert.Throws<InvalidDataException>(() => Decode<NativeMaintenanceGrant>("PrepareNativeMaintenance", refused));
        Assert.Throws<InvalidDataException>(() => Decode<NativeMaintenanceGrant>("PrepareNativeMaintenance", grant, brand: "another"));
        using var notNull = JsonDocument.Parse("{}");
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeResult<object?>("ConfirmNativeMaintenance", notNull.RootElement, "wootc"));
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
    public async Task TheShellSendsOnlyThePlanAndTheIntent()
    {
        using var toEngine = new AnonymousPipeServerStream(PipeDirection.Out);
        using var toShell = new AnonymousPipeServerStream(PipeDirection.Out);
        using var engineReads = new AnonymousPipeClientStream(PipeDirection.In, toEngine.ClientSafePipeHandle);
        using var shellReads = new AnonymousPipeClientStream(PipeDirection.In, toShell.ClientSafePipeHandle);
        var engine = new Duplex(engineReads, toShell);
        var session = new NativeEngineSession(new Duplex(shellReads, toEngine), Process.GetCurrentProcess(), expectedBrand: "wootc", installSession: Session);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var recorded = Recorded();
        async Task<JsonElement?> Answer(string method, string result)
        {
            using var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(engine, 4096, deadline.Token));
            Assert.Equal(method, request.RootElement.GetProperty("method").GetString());
            JsonElement? parameters = request.RootElement.TryGetProperty("params", out var value) ? value.Clone() : null;
            byte[] frame = Encoding.UTF8.GetBytes($"{{\"jsonrpc\":\"2.0\",\"id\":{request.RootElement.GetProperty("id").GetInt64()},\"result\":{result}}}\n");
            await engine.WriteAsync(frame, deadline.Token); await engine.FlushAsync(deadline.Token);
            return parameters;
        }
        var reading = session.ReadUninstallInfoAsync(deadline.Token);
        Assert.Null(await Answer("GetUninstallInfo", recorded[0].Result.ToJsonString()));
        Assert.True((await reading).Found);
        var inspecting = session.InspectBootAsync(deadline.Token);
        Assert.Null(await Answer("InspectBoot", recorded[2].Result.ToJsonString()));
        Assert.Equal("wootc-listed", (await inspecting).BootState);
        var preparing = session.PrepareMaintenanceAsync(new NativeMaintenancePlan { Action = "uninstall", DeleteRootDisk = true, RemovePartition = true }, deadline.Token);
        var plan = await Answer("PrepareNativeMaintenance", recorded[3].Result.ToJsonString());
        Assert.Equal(["action", "deleteRootDisk", "removePartition"], plan!.Value.EnumerateObject().Select(property => property.Name));
        var grant = await preparing;
        var confirming = session.ConfirmMaintenanceAsync(grant, deadline.Token);
        var consent = await Answer("ConfirmNativeMaintenance", "null");
        Assert.Equal(["kind", "protocolVersion", "session", "brandId", "intentId", "action"], consent!.Value.EnumerateObject().Select(property => property.Name));
        Assert.Equal("confirm-maintenance", consent.Value.GetProperty("kind").GetString());
        Assert.Equal("fedcba9876543210fedcba9876543210", consent.Value.GetProperty("intentId").GetString());
        await confirming;
        Assert.Equal("rpc-maintenance-plan", NativeEngineSession.RpcStage("PrepareNativeMaintenance"));
        Assert.Equal("rpc-maintenance-consent", NativeEngineSession.RpcStage("ConfirmNativeMaintenance"));
        Assert.Equal("rpc-boot-check", NativeEngineSession.RpcStage("InspectBoot"));
        Assert.Equal("rpc-uninstall-info", NativeEngineSession.RpcStage("GetUninstallInfo"));
    }

    [Fact]
    public async Task AnAssessmentSessionHasNoMaintenanceActions()
    {
        using var toEngine = new AnonymousPipeServerStream(PipeDirection.Out);
        using var toShell = new AnonymousPipeServerStream(PipeDirection.Out);
        using var shellReads = new AnonymousPipeClientStream(PipeDirection.In, toShell.ClientSafePipeHandle);
        IMaintenanceEngineSession session = new NativeEngineSession(new Duplex(shellReads, toEngine), Process.GetCurrentProcess(), expectedBrand: "wootc");
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ReadUninstallInfoAsync(CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.InspectBootAsync(CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.PrepareMaintenanceAsync(new NativeMaintenancePlan { Action = "uninstall" }, CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ConfirmMaintenanceAsync(new NativeMaintenanceGrant { Session = Session }, CancellationToken.None));
    }
}
