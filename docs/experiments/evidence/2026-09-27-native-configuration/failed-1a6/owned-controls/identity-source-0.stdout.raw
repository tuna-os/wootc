using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Native;

internal sealed class NativeEngineSession : IConfigurationEngineSession
{
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

    public NativeEngineSession(Stream pipe, Process engine, Action<string, Exception?>? observe = null, string? expectedBrand = null) : this(pipe, engine, TimeSpan.FromSeconds(30), observe, expectedBrand) { }

    internal NativeEngineSession(Stream pipe, Process engine, TimeSpan disconnectTimeout, Action<string, Exception?>? observe = null, string? expectedBrand = null)
    {
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
                    // establish startup state. Later views may consume them.
                    if (!root.TryGetProperty("method", out _)) throw new InvalidDataException("Engine RPC frame has neither response nor notification identity");
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
        "GetRecoveryVerdict" => "rpc-recovery", "GetNativeConfiguration" => "rpc-configuration", _ => "rpc-other"
    };

    internal async Task<T> CallAsync<T>(string method, CancellationToken token, Action<long>? requestFlushed = null)
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
            byte[] request = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method }) + "\n");
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
                ? (T)(object)NativeConfigurationProtocol.Decode(result, expectedBrand ?? throw new InvalidDataException("Authenticated configuration brand is unavailable")) : NativeProtocol.DecodeStartup<T>(method, result);
            observe?.Invoke(RpcStage(method) + "-complete", null);
            return decoded;
        }
        catch (Exception error) { observe?.Invoke(stage, error); throw; }
        finally { pending.TryRemove(id, out _); pendingMethods.TryRemove(id, out _); }
    }

    public async Task<StartupSnapshot> ReadStartupAsync(CancellationToken cancellationToken)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
        var status = await CallAsync<InstallStatus>("GetStatus", deadline.Token);
        var lifecycle = await CallAsync<LifecycleState>("GetLastRun", deadline.Token);
        var recovery = await CallAsync<RecoveryVerdict>("GetRecoveryVerdict", deadline.Token);
        return new(status, recovery, lifecycle);
    }

    public async Task<NativeConfigurationSnapshot> ReadConfigurationAsync(CancellationToken cancellationToken, Action<long>? requestFlushed = null)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(TimeSpan.FromSeconds(15));
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
