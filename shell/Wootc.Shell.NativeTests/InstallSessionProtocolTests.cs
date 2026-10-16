using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Wootc.Shell.Engine;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

public sealed class InstallSessionProtocolTests
{
    private const string Session = "0123456789abcdef0123456789abcdef";
    private const string Intent = "fedcba9876543210fedcba9876543210";

    private static JsonObject Grant() => new()
    {
        ["schemaVersion"] = 1, ["session"] = Session, ["brandId"] = "wootc", ["intentId"] = Intent,
        ["imageRef"] = "ghcr.io/tuna-os/yellowfin:gnome", ["storageDrive"] = "D", ["diskSizeGB"] = 40, ["encryption"] = "none",
        ["bitLockerOn"] = false, ["bitLockerRecoveryKeyWarning"] = false, ["fastStartupOn"] = true, ["secureBootChainWarning"] = "",
    };

    private static NativeInstallGrant Decode(string json, string? brand = "wootc")
    {
        using var document = JsonDocument.Parse(json);
        return NativeProtocol.DecodeInstallGrant(document.RootElement, brand);
    }

    [Fact]
    public void AnExactGrantDecodes()
    {
        var grant = Decode(Grant().ToJsonString());
        Assert.Equal((Session, Intent, "D", 40, true), (grant.Session, grant.IntentId, grant.StorageDrive, grant.DiskSizeGB, grant.FastStartupOn));
        using var empty = JsonDocument.Parse("null");
        Assert.Null(NativeProtocol.DecodeResult<object?>("ConfirmNativeInstall", empty.RootElement, "wootc"));
        using var unexpected = JsonDocument.Parse("{}");
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeResult<object?>("ConfirmNativeInstall", unexpected.RootElement, "wootc"));
        Assert.Equal("rpc-plan", NativeEngineSession.RpcStage("PrepareNativeInstall"));
        Assert.Equal("rpc-consent", NativeEngineSession.RpcStage("ConfirmNativeInstall"));
    }

    public static TheoryData<string> Refused()
    {
        string Mutate(Action<JsonObject> change) { var node = Grant(); change(node); return node.ToJsonString(); }
        return new()
        {
            Mutate(node => node["password"] = "public synthetic password"),
            Mutate(node => node.Remove("intentId")),
            Mutate(node => node["intentId"] = "FEDCBA9876543210FEDCBA9876543210"),
            Mutate(node => node["session"] = "short"),
            Mutate(node => node["brandId"] = "foreign"),
            Mutate(node => node["schemaVersion"] = 2),
            Mutate(node => node["storageDrive"] = "d"),
            Mutate(node => node["storageDrive"] = "DE"),
            Mutate(node => node["diskSizeGB"] = 19),
            Mutate(node => node["encryption"] = "tpm2-luks"),
            Mutate(node => node["fastStartupOn"] = "true"),
            Mutate(node => node["secureBootChainWarning"] = new string('x', 1025)),
            Grant().ToJsonString().Replace("\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1"),
        };
    }

    [Theory]
    [MemberData(nameof(Refused))]
    public void AMalformedOrForeignGrantIsRefused(string json) =>
        Assert.Throws<InvalidDataException>(() => Decode(json));

    [Fact]
    public void AGrantNeedsTheAuthenticatedBrand() =>
        Assert.Throws<InvalidDataException>(() => Decode(Grant().ToJsonString(), brand: null));

    [Fact]
    public void OnlyAnInstallRequestLaunchesAnInstallPurposeEngine()
    {
        string engine = Path.Combine(Path.GetTempPath(), "wootc-engine.exe");
        Assert.DoesNotContain("--purpose", RunasLaunch.Create(engine, Session, 42).ArgumentList);
        var install = RunasLaunch.Create(engine, Session, 42, install: true).ArgumentList.ToArray();
        Assert.Equal(new[] { "--native-serve", "--session", Session, "--source-pid", "42", "--purpose", "install" }, install);
    }

    // A duplex stream over two anonymous pipes stands in for the named pipe.
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
    public async Task ThePlanAndTheConsentCrossThePipeWithExactFields()
    {
        using var toEngine = new AnonymousPipeServerStream(PipeDirection.Out);
        using var engineReads = new AnonymousPipeClientStream(PipeDirection.In, toEngine.ClientSafePipeHandle);
        using var toShell = new AnonymousPipeServerStream(PipeDirection.Out);
        using var shellReads = new AnonymousPipeClientStream(PipeDirection.In, toShell.ClientSafePipeHandle);
        var engineSide = new Duplex(engineReads, toShell);
        var session = new NativeEngineSession(new Duplex(shellReads, toEngine), Process.GetCurrentProcess(), expectedBrand: "wootc", installSession: Session);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var plan = new InstallConfig { ImageRef = "ghcr.io/tuna-os/yellowfin:gnome", DiskSizeGB = 40, Username = "linux_user", Password = "public synthetic password", Hostname = "linux-pc", Bootloader = "auto", StorageDrive = "D", Encryption = "none" };
        var preparing = session.PrepareInstallAsync(plan, deadline.Token);
        using (var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(engineSide, 65536, deadline.Token)))
        {
            Assert.Equal("PrepareNativeInstall", request.RootElement.GetProperty("method").GetString());
            var parameters = request.RootElement.GetProperty("params");
            Assert.Equal(new[] { "bootloader", "composeFs", "diskSizeGB", "encryption", "hostname", "imageRef", "luksPassphrase", "password", "storageDrive", "username", "windowsLook" },
                parameters.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal).ToArray());
            Assert.Equal("public synthetic password", parameters.GetProperty("password").GetString());
            await engineSide.WriteAsync(Encoding.UTF8.GetBytes($"{{\"jsonrpc\":\"2.0\",\"id\":{request.RootElement.GetProperty("id").GetInt64()},\"result\":{Grant().ToJsonString()}}}\n"), deadline.Token);
            await engineSide.FlushAsync(deadline.Token);
        }
        var grant = await preparing;
        var confirming = session.ConfirmInstallAsync(grant, deadline.Token);
        using (var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(engineSide, 65536, deadline.Token)))
        {
            Assert.Equal("ConfirmNativeInstall", request.RootElement.GetProperty("method").GetString());
            var parameters = request.RootElement.GetProperty("params");
            Assert.Equal(new[] { "brandId", "intentId", "kind", "protocolVersion", "session" }, parameters.EnumerateObject().Select(property => property.Name).Order(StringComparer.Ordinal).ToArray());
            Assert.Equal(("confirm-install", 1, Session, "wootc", Intent), (parameters.GetProperty("kind").GetString(), parameters.GetProperty("protocolVersion").GetInt32(), parameters.GetProperty("session").GetString(), parameters.GetProperty("brandId").GetString(), parameters.GetProperty("intentId").GetString()));
            await engineSide.WriteAsync(Encoding.UTF8.GetBytes($"{{\"jsonrpc\":\"2.0\",\"id\":{request.RootElement.GetProperty("id").GetInt64()},\"result\":null}}\n"), deadline.Token);
            await engineSide.FlushAsync(deadline.Token);
        }
        await confirming;
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ConfirmInstallAsync(new NativeInstallGrant { Session = "ffffffffffffffffffffffffffffffff" }, deadline.Token));
        toShell.Dispose();
    }

    [Fact]
    public async Task AnAssessmentSessionCannotSendAPlan()
    {
        using var toShell = new AnonymousPipeServerStream(PipeDirection.Out);
        using var shellReads = new AnonymousPipeClientStream(PipeDirection.In, toShell.ClientSafePipeHandle);
        var session = new NativeEngineSession(new Duplex(shellReads, Stream.Null), Process.GetCurrentProcess(), expectedBrand: "wootc");
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.PrepareInstallAsync(new InstallConfig(), CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ConfirmInstallAsync(new NativeInstallGrant { Session = Session }, CancellationToken.None));
        toShell.Dispose();
    }
}
