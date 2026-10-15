using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Native;

internal sealed class NativeEngineSession : IConfigurationEngineSession, IInstallEngineSession
{
    // Set only for an install-purpose session; an assessment session refuses
    // install calls locally as well as in the engine.
    private readonly string? installSession;
    private readonly Stream pipe;
    private readonly string? expectedBrand;
    private readonly Process engine;
    private readonly TimeSpan disconnectTimeout;
    private readonly SemaphoreSlim writes = new(1, 1);
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> pending = new();
    private readonly ConcurrentDictionary<long, string> pendingMethods = new();
    private readonly CancellationTokenSource readerStop = new();
    private readonly Task reader;
    private long nextId;
    private volatile bool disconnected;
    private Exception? receiveFailure;
    private readonly Action<string, Exception?>? observe;

    public NativeEngineSession(Stream pipe, Process engine, Action<string, Exception?>? observe = null, string? expectedBrand = null, string? installSession = null) : this(pipe, engine, TimeSpan.FromSeconds(30), observe, expectedBrand, installSession) { }

    internal NativeEngineSession(Stream pipe, Process engine, TimeSpan disconnectTimeout, Action<string, Exception?>? observe = null, string? expectedBrand = null, string? installSession = null)
    {
        this.installSession = installSession;
        this.pipe = pipe;
        this.expectedBrand = expectedBrand;
        this.engine = engine;
        this.disconnectTimeout = disconnectTimeout;
        this.observe = observe;
        reader = ReceiveAsync();
    }

    internal static async Task<byte[]> ReadLineAsync(Stream stream, int limit, CancellationToken token)
    {
        using var line = new MemoryStream();
        byte[] next = new byte[1];
        while (line.Length < limit)
        {
            int count = await stream.ReadAsync(next, token);
            if (count == 0) throw new EndOfStreamException("The authenticated engine disconnected");
            if (next[0] == '\n') return line.ToArray();
            line.WriteByte(next[0]);
        }
        throw new InvalidDataException("Engine frame exceeds its size limit");
    }

    private async Task ReceiveAsync()
    {
        Exception failure = new EndOfStreamException("The authenticated engine disconnected");
        try
        {
            while (!readerStop.IsCancellationRequested)
            {
                using var message = NativeProtocol.ParseObject(await ReadLineAsync(pipe, 1024 * 1024, readerStop.Token));
                var root = message.RootElement;
                if (!root.TryGetProperty("jsonrpc", out var version) || version.GetString() != "2.0") throw new InvalidDataException("Unsupported engine RPC frame");
                if (!root.TryGetProperty("id", out var id))
                {
                    // Progress notifications do not acknowledge requests or
                    // establish startup state. Only an install session reads
                    // its own install:progress; a malformed one ends the session.
                    if (!root.TryGetProperty("method", out var method)) throw new InvalidDataException("Engine RPC frame has neither response nor notification identity");
                    if (installSession is not null && method.ValueKind == JsonValueKind.String && method.GetString() == "install:progress")
                    {
                        if (!root.TryGetProperty("params", out var parameters)) throw new InvalidDataException("Install progress has no event");
                        var update = NativeProtocol.DecodeProgress(parameters);
                        try { ProgressReceived?.Invoke(update); } catch { /* A view failure must not end the engine session. */ }
                    }
                    continue;
                }
                if (!id.TryGetInt64(out long value)) throw new InvalidDataException("Invalid engine response identity");
                bool hasError = root.TryGetProperty("error", out _);
                bool hasResult = root.TryGetProperty("result", out _);
                if (hasError == hasResult) throw new InvalidDataException("Ambiguous engine response outcome");
                if (!pending.TryRemove(value, out var completion)) continue; // Canceled request's late response.
                pendingMethods.TryRemove(value, out var responseMethod);
                if (root.TryGetProperty("error", out var error) && error.TryGetProperty("data", out var storageData))
                {
                    if (responseMethod != "GetNativeConfiguration") completion.TrySetException(new InvalidDataException("Unexpected diagnostic response"));
                    else { try { completion.TrySetException(StorageObservationFailure.Decode(storageData)); } catch { completion.TrySetException(new InvalidDataException("Storage diagnostic refused")); } }
                }
                else if (root.TryGetProperty("error", out error))
                    completion.TrySetException(new InvalidDataException(error.TryGetProperty("message", out var text) ? text.GetString() ?? "Engine request failed" : "Engine request failed"));
                else if (root.TryGetProperty("result", out var result)) completion.TrySetResult(result.Clone());
                else completion.TrySetException(new InvalidDataException("Engine response has no result"));
            }
        }
        catch (Exception error) { failure = error; }
        finally { Volatile.Write(ref receiveFailure, failure); foreach (var (id, completion) in pending) if (pending.TryRemove(id, out _)) completion.TrySetException(failure); }
    }

    internal static string RpcStage(string method) => method switch
    {
        "GetStatus" => "rpc-status", "GetLastRun" => "rpc-lifecycle",
        "GetRecoveryVerdict" => "rpc-recovery", "GetInstallRecovery" => "rpc-install", "GetNativeConfiguration" => "rpc-configuration",
        "PrepareNativeInstall" => "rpc-plan", "ConfirmNativeInstall" => "rpc-consent", "CancelInstall" => "rpc-cancel", "Reboot" => "rpc-restart", _ => "rpc-other"
    };

    internal Task<T> CallAsync<T>(string method, CancellationToken token, Action<long>? requestFlushed = null) =>
        CallAsync<T>(method, null, token, requestFlushed);

    internal async Task<T> CallAsync<T>(string method, object? parameters, CancellationToken token, Action<long>? requestFlushed = null)
    {
        long id = Interlocked.Increment(ref nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!pending.TryAdd(id, completion)) throw new InvalidOperationException("Duplicate engine request identity");
        pendingMethods[id] = method;
        string stage = RpcStage(method) + "-request";
        try
        {
            observe?.Invoke(stage, null);
            if (disconnected || engine.HasExited) throw new EndOfStreamException("The authenticated engine disconnected");
            if (Volatile.Read(ref receiveFailure) is not null) throw new EndOfStreamException("The authenticated engine disconnected");
            object frame = parameters is null ? new { jsonrpc = "2.0", id, method } : new { jsonrpc = "2.0", id, method, @params = parameters };
            byte[] request = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(frame) + "\n");
            await writes.WaitAsync(token);
            try { await pipe.WriteAsync(request, token); await pipe.FlushAsync(token); }
            finally { writes.Release(); }
            if (method == "GetNativeConfiguration") requestFlushed?.Invoke(id);
            stage = RpcStage(method) + "-response";
            observe?.Invoke(stage, null);
            var result = await completion.Task.WaitAsync(token);
            stage = RpcStage(method) + "-decode";
            observe?.Invoke(stage, null);
            var decoded = method == "GetNativeConfiguration" && typeof(T) == typeof(NativeConfigurationSnapshot)
                ? (T)(object)NativeConfigurationProtocol.Decode(result, expectedBrand ?? throw new InvalidDataException("Authenticated configuration brand is unavailable")) : NativeProtocol.DecodeResult<T>(method, result, expectedBrand);
            observe?.Invoke(RpcStage(method) + "-complete", null);
            return decoded;
        }
        catch (Exception error) { observe?.Invoke(stage, error); throw; }
        finally { pending.TryRemove(id, out _); pendingMethods.TryRemove(id, out _); }
    }

    // The plan crosses the authenticated pipe once, in this session only, with
    // exactly the fields the engine accepts. Two storage observations run
    // before a grant, so the wait allows two configuration budgets.
    public async Task<NativeInstallGrant> PrepareInstallAsync(InstallConfig plan, CancellationToken cancellationToken)
    {
        if (installSession is null) throw new InvalidOperationException("This engine session is not an install session");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(110));
        var parameters = new Dictionary<string, object>
        {
            ["imageRef"] = plan.ImageRef, ["diskSizeGB"] = plan.DiskSizeGB, ["username"] = plan.Username, ["password"] = plan.Password,
            ["hostname"] = plan.Hostname, ["bootloader"] = plan.Bootloader, ["composeFs"] = plan.ComposeFs, ["storageDrive"] = plan.StorageDrive,
            ["encryption"] = plan.Encryption, ["luksPassphrase"] = plan.LuksPassphrase, ["windowsLook"] = plan.WindowsLook,
        };
        var grant = await CallAsync<NativeInstallGrant>("PrepareNativeInstall", parameters, deadline.Token);
        if (grant.Session != installSession) throw new InvalidDataException("The install grant names another session");
        return grant;
    }

    public event Action<ProgressEvent>? ProgressReceived;

    public Task<InstallStatus> GetInstallStatusAsync(CancellationToken cancellationToken) =>
        installSession is null ? throw new InvalidOperationException("This engine session is not an install session")
            : CallAsync<InstallStatus>("GetStatus", cancellationToken);

    public async Task CancelInstallAsync(CancellationToken cancellationToken)
    {
        if (installSession is null) throw new InvalidOperationException("This engine session is not an install session");
        await CallAsync<object?>("CancelInstall", cancellationToken);
    }

    public async Task RebootAsync(CancellationToken cancellationToken)
    {
        if (installSession is null) throw new InvalidOperationException("This engine session is not an install session");
        await CallAsync<object?>("Reboot", cancellationToken);
    }

    // Only the intent's identity is sent: no plan field can travel with consent.
    public async Task ConfirmInstallAsync(NativeInstallGrant grant, CancellationToken cancellationToken)
    {
        if (installSession is null || grant.Session != installSession) throw new InvalidOperationException("This engine session did not grant that intent");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(60));
        await CallAsync<object?>("ConfirmNativeInstall", new { kind = "confirm-install", protocolVersion = 1, session = grant.Session, brandId = grant.BrandId, intentId = grant.IntentId }, deadline.Token);
    }

    public async Task<StartupSnapshot> ReadStartupAsync(CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        var status = await CallAsync<InstallStatus>("GetStatus", deadline.Token);
        var lifecycle = await CallAsync<LifecycleState>("GetLastRun", deadline.Token);
        var recovery = await CallAsync<RecoveryVerdict>("GetRecoveryVerdict", deadline.Token);
        var install = await CallAsync<InstallRecoverySummary>("GetInstallRecovery", deadline.Token);
        return new(status, recovery, lifecycle, install);
    }

    public async Task<NativeConfigurationSnapshot> ReadConfigurationAsync(CancellationToken cancellationToken, Action<long>? requestFlushed = null)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        // Longer than the engine's own configuration budget (40 s in
        // app/native_configuration.go), so a slow read ends with the
        // engine's typed storage diagnostic and not a shell-side timeout.
        deadline.CancelAfter(TimeSpan.FromSeconds(50));
        return await CallAsync<NativeConfigurationSnapshot>("GetNativeConfiguration", deadline.Token, requestFlushed);
    }

    public async ValueTask DisposeAsync()
    {
        if (!disconnected)
        {
            disconnected = true;
            readerStop.Cancel();
            await pipe.DisposeAsync(); // Engine disconnect cancels the production pipeline.
        }
        await reader;
        // Preserve the retained process and session authority if cleanup is
        // pending. The controller blocks retries; a later Dispose retries wait.
        using var deadline = new CancellationTokenSource(disconnectTimeout);
        observe?.Invoke("session-cleanup-wait", null);
        try { await engine.WaitForExitAsync(deadline.Token); }
        catch (OperationCanceledException error) { observe?.Invoke("session-cleanup-pending", error); throw new IOException("Engine cleanup is still pending; do not reboot"); }
        observe?.Invoke("session-cleanup-exited", null);
        engine.Dispose();
    }
}
