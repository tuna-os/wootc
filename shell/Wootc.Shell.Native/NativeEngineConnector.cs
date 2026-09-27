using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32.SafeHandles;
using Wootc.Shell.Core;

namespace Wootc.Shell.Native;

public sealed class NativeEngineConnector : IEngineConnector
{
    private readonly string directory;
    public NativeEngineConnector(string directory) { this.directory = directory; }

    public async Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!ProtectedPackage.LowerHex(request.SessionId, 32)) return new(ConnectionOutcome.Incompatible, Reason: "Invalid native session identity");
        var package = ProtectedPackage.Read(directory);
        using var sourceProcess = Process.GetCurrentProcess();
        var source = WindowsPeer.Observe(sourceProcess);
        if (!string.Equals(Path.GetFullPath(source.ImagePath), Path.Combine(package.Directory, "Wootc.Shell.exe"), StringComparison.OrdinalIgnoreCase))
            return new(ConnectionOutcome.Incompatible, Reason: "The shell is outside this protected preview package");
        var start = new ProcessStartInfo(package.EnginePath) { UseShellExecute = true, Verb = "runas", WorkingDirectory = package.Directory };
        start.ArgumentList.Add("--native-serve"); start.ArgumentList.Add("--session"); start.ArgumentList.Add(request.SessionId);
        start.ArgumentList.Add("--source-pid"); start.ArgumentList.Add(sourceProcess.Id.ToString(System.Globalization.CultureInfo.InvariantCulture));
        Process? engine;
        try
        {
            // ShellExecute may await interactive UAC. Do not abandon an
            // unresolved launch on cancellation: retain and close any returned
            // engine before allowing another permission request.
            engine = await Task.Run(() => Process.Start(start));
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223)
        { return new(ConnectionOutcome.PermissionDeclined, Reason: "Administrator permission was declined. You can retry."); }
        if (engine is null) return new(ConnectionOutcome.Unavailable, Reason: "Windows did not return the launched engine process");
        _ = engine.Handle;
        NamedPipeClientStream? pipe = null;
        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(TimeSpan.FromSeconds(15));
            string name = @"\\.\pipe\wootc-preview-" + request.SessionId;
            while (pipe is null)
            {
                deadline.Token.ThrowIfCancellationRequested();
                if (engine.HasExited) throw new IOException("The engine refused this install context or package before connection");
                // GenericWrite includes FILE_CREATE_PIPE_INSTANCE. Request the
                // same narrow access mask as the engine's source-user ACE.
                var handle = CreateFile(name, 0x0012019b, 0, 0, 3, 0x40000000 | 0x00100000 | 0x00020000, 0);
                if (!handle.IsInvalid) pipe = new NamedPipeClientStream(PipeDirection.InOut, true, true, handle);
                else
                {
                    int error = Marshal.GetLastWin32Error(); handle.Dispose();
                    if (error is not (2 or 231)) throw new Win32Exception(error);
                    await Task.Delay(25, deadline.Token);
                }
            }
            WindowsPeer.VerifyPipeServer(pipe.SafePipeHandle, engine, source, package.EnginePath);
            var hello = new Handshake { Kind = "hello", ProtocolVersion = 1, Session = request.SessionId, BuildId = package.Manifest.BuildId, BrandId = package.Manifest.BrandId };
            byte[] encoded = JsonSerializer.SerializeToUtf8Bytes(hello);
            await pipe.WriteAsync(encoded, deadline.Token); await pipe.WriteAsync(new byte[] { (byte)'\n' }, deadline.Token); await pipe.FlushAsync(deadline.Token);
            byte[] line = await NativeEngineSession.ReadLineAsync(pipe, 16384, deadline.Token);
            var ready = JsonSerializer.Deserialize<Handshake>(line, new JsonSerializerOptions { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow });
            if (ready is null || ready.Kind != "ready" || ready.ProtocolVersion != 1 || ready.Session != hello.Session || ready.BuildId != hello.BuildId || ready.BrandId != hello.BrandId)
                throw new InvalidDataException("The engine acknowledgement differs from this session package");
            WindowsPeer.VerifyPipeServer(pipe.SafePipeHandle, engine, source, package.EnginePath);
            return new(ConnectionOutcome.Connected, new NativeEngineSession(pipe, engine));
        }
        catch
        {
            // There has been no StartInstall RPC. Close the private transport
            // and await this exact retained engine; never kill by name/PID scan.
            if (pipe is not null) await pipe.DisposeAsync();
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            try { await engine.WaitForExitAsync(cleanup.Token); }
            catch (OperationCanceledException) { return new(ConnectionOutcome.Unavailable, new NativeEngineSession(Stream.Null, engine), "Engine disconnect is still pending"); }
            engine.Dispose();
            throw;
        }
    }

    private sealed class Handshake
    {
        [JsonPropertyName("kind")] public string Kind { get; set; } = "";
        [JsonPropertyName("protocolVersion")] public int ProtocolVersion { get; set; }
        [JsonPropertyName("session")] public string Session { get; set; } = "";
        [JsonPropertyName("buildId")] public string BuildId { get; set; } = "";
        [JsonPropertyName("brandId")] public string BrandId { get; set; } = "";
    }
    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafePipeHandle CreateFile(string name, uint access, uint share, nint security, uint creation, uint flags, nint template);
}
