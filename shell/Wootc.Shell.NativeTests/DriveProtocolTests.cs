using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

// The drive channel crosses the authenticated assessment session with the
// exact shapes app/serve.go accepts: no parameters for the directive, one
// string for a report, and a string or null back.
public sealed class DriveProtocolTests
{
    private sealed class Duplex(Stream read, Stream write) : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => true;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() => write.Flush();
        public override Task FlushAsync(CancellationToken cancellationToken) => write.FlushAsync(cancellationToken);
        public override int Read(byte[] buffer, int offset, int count) => read.Read(buffer, offset, count);
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => read.ReadAsync(buffer, cancellationToken);
        public override void Write(byte[] buffer, int offset, int count) => write.Write(buffer, offset, count);
        public override ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default) => write.WriteAsync(buffer, cancellationToken);
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
    public void DriveResultsDecodeToTheirExactShapes()
    {
        using var directive = JsonDocument.Parse("\"{\\\"schemaVersion\\\":1}\"");
        Assert.Equal("{\"schemaVersion\":1}", NativeProtocol.DecodeResult<string>("E2EDriveDirective", directive.RootElement, "wootc"));
        using var empty = JsonDocument.Parse("\"\"");
        Assert.Equal("", NativeProtocol.DecodeResult<string>("E2EDriveDirective", empty.RootElement, "wootc"));
        using var none = JsonDocument.Parse("null");
        Assert.Null(NativeProtocol.DecodeResult<object?>("E2EDriveReport", none.RootElement, "wootc"));
        Assert.Null(NativeProtocol.DecodeResult<object?>("E2EDriveReady", none.RootElement, "wootc"));
        foreach (string refused in new[] { "null", "{}", "7", JsonSerializer.Serialize(new string('x', 16385)) })
        {
            using var document = JsonDocument.Parse(refused);
            Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeResult<string>("E2EDriveDirective", document.RootElement, "wootc"));
        }
        using var unexpected = JsonDocument.Parse("{}");
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeResult<object?>("E2EDriveReport", unexpected.RootElement, "wootc"));
    }

    [Fact]
    public async Task TheAssessmentSessionCarriesTheChannel()
    {
        using var pair = new Pair();
        var session = pair.Session(null);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        async Task<JsonElement> Answer(string method, string result)
        {
            using var request = JsonDocument.Parse(await NativeEngineSession.ReadLineAsync(pair.Engine, 65536, deadline.Token));
            Assert.Equal(method, request.RootElement.GetProperty("method").GetString());
            var copy = request.RootElement.Clone();
            await pair.SendAsync($"{{\"jsonrpc\":\"2.0\",\"id\":{request.RootElement.GetProperty("id").GetInt64()},\"result\":{result}}}", deadline.Token);
            return copy;
        }
        var reading = session.ReadDriveDirectiveAsync(deadline.Token);
        var sent = await Answer("E2EDriveDirective", "\"raw directive\"");
        Assert.False(sent.TryGetProperty("params", out _));
        Assert.Equal("raw directive", await reading);

        var reporting = session.ReportDriveAsync("{\"screen\":\"launchpad\"}", deadline.Token);
        sent = await Answer("E2EDriveReport", "null");
        Assert.Equal(JsonValueKind.Array, sent.GetProperty("params").ValueKind);
        Assert.Equal("{\"screen\":\"launchpad\"}", Assert.Single(sent.GetProperty("params").EnumerateArray()).GetString());
        await reporting;

        var ready = session.ReportDriveReadyAsync("{\"schemaVersion\":1,\"screen\":\"loading\"}", deadline.Token);
        sent = await Answer("E2EDriveReady", "null");
        Assert.Equal("{\"schemaVersion\":1,\"screen\":\"loading\"}", Assert.Single(sent.GetProperty("params").EnumerateArray()).GetString());
        await ready;
    }

    [Fact]
    public async Task AnInstallSessionRefusesTheChannelLocally()
    {
        using var pair = new Pair();
        var session = pair.Session("0123456789abcdef0123456789abcdef");
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ReadDriveDirectiveAsync(CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ReportDriveAsync("{}", CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => session.ReportDriveReadyAsync("{}", CancellationToken.None));
    }
}
