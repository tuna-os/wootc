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
    private readonly Action<string>? observe;
    public NativeEngineConnector(string directory, Action<string>? observe = null) { this.directory = directory; this.observe = observe; }
    internal static string DescribeFailure(Exception? error)
    {
        string kind = error switch { null => "none", OperationCanceledException => "deadline", Win32Exception => "win32", UnauthorizedAccessException => "access", InvalidDataException => "protocol", IOException => "io", _ => "unexpected" };
        return $"Failure:{kind}; HResult:{error?.HResult ?? 0}; NativeCode:{(error as Win32Exception)?.NativeErrorCode ?? 0}";
    }
    private void Observe(string stage, Exception? error = null, Process? engine = null)
    {
        string process = engine is null ? "not-launched" : engine.HasExited ? $"exited:{engine.ExitCode}" : "retained-running";
        observe?.Invoke($"Stage:{stage}; {DescribeFailure(error)}; Engine:{process}");
    }

    public async Task<ConnectionAttempt> ConnectAsync(ConnectRequest request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!ProtectedPackage.LowerHex(request.SessionId, 32)) return new(ConnectionOutcome.Incompatible, Reason: "Invalid native session identity");
        Observe("package");
        var package = ProtectedPackage.Read(directory);
        using var sourceProcess = Process.GetCurrentProcess();
        var source = WindowsPeer.Observe(sourceProcess);
        if (!string.Equals(Path.GetFullPath(source.ImagePath), Path.Combine(package.Directory, "Wootc.Shell.exe"), StringComparison.OrdinalIgnoreCase))
            return new(ConnectionOutcome.Incompatible, Reason: "The shell is outside this protected preview package");
        var start = RunasLaunch.Create(package.EnginePath, request.SessionId, sourceProcess.Id);
        // Do not abandon a pending interactive consent request. Any returned
        // process remains our responsibility through disconnect completion.
        Observe("launch");
        var launched = await RunasLaunch.StartAsync(start, Process.Start);
        if (launched.Declined) return new(ConnectionOutcome.PermissionDeclined, Reason: "Administrator permission was declined. You can retry.");
        Process? engine = launched.Process;
        if (engine is null) return new(ConnectionOutcome.Unavailable, Reason: "Windows did not return the launched engine process");
        _ = engine.Handle;
        NamedPipeClientStream? pipe = null;
        string stage = "pipe-open";
        Observe(stage, engine: engine);
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
            stage = "peer";
            Observe(stage, engine: engine);
            WindowsPeer.VerifyPipeServer(pipe.SafePipeHandle, engine, source, package.EnginePath);
            stage = "hello-ready";
            Observe(stage, engine: engine);
            var hello = new NativeProtocol.Handshake { Kind = "hello", ProtocolVersion = 1, Session = request.SessionId, BuildId = package.Manifest.BuildId, BrandId = package.Manifest.BrandId };
            byte[] encoded = JsonSerializer.SerializeToUtf8Bytes(hello);
            await pipe.WriteAsync(encoded, deadline.Token); await pipe.WriteAsync(new byte[] { (byte)'\n' }, deadline.Token); await pipe.FlushAsync(deadline.Token);
            byte[] line = await NativeEngineSession.ReadLineAsync(pipe, 16384, deadline.Token);
            NativeProtocol.ValidateReady(line, hello);
            WindowsPeer.VerifyPipeServer(pipe.SafePipeHandle, engine, source, package.EnginePath);
            Observe("authenticated", engine: engine);
            return new(ConnectionOutcome.Connected, new NativeEngineSession(pipe, engine, (phase, error) => Observe(phase, error, engine)));
        }
        catch (Exception error)
        {
            Observe(stage, error, engine);
            // There has been no StartInstall RPC. Close the private transport
            // and await this exact retained engine; never kill by name/PID scan.
            if (pipe is not null) await pipe.DisposeAsync();
            using var cleanup = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            try { await engine.WaitForExitAsync(cleanup.Token); }
            catch (OperationCanceledException) { Observe("cleanup-pending", error, engine); return new(ConnectionOutcome.Unavailable, new NativeEngineSession(Stream.Null, engine), "Engine disconnect is still pending"); }
            Observe("cleanup-exited", error, engine);
            engine.Dispose();
            throw;
        }
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafePipeHandle CreateFile(string name, uint access, uint share, nint security, uint creation, uint flags, nint template);
}
