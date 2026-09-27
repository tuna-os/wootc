using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Native;

internal sealed class NativeEngineSession : IEngineSession
{
    private readonly Stream pipe;
    private readonly Process engine;
    private readonly SemaphoreSlim writes = new(1, 1);
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> pending = new();
    private readonly CancellationTokenSource readerStop = new();
    private readonly Task reader;
    private long nextId;
    private volatile bool disconnected;
    private Exception? receiveFailure;

    public NativeEngineSession(Stream pipe, Process engine)
    {
        this.pipe = pipe;
        this.engine = engine;
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
                using var message = JsonDocument.Parse(await ReadLineAsync(pipe, 1024 * 1024, readerStop.Token));
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
                if (!pending.TryRemove(value, out var completion)) continue; // Canceled request's late response.
                if (root.TryGetProperty("error", out var error))
                    completion.TrySetException(new InvalidDataException(error.TryGetProperty("message", out var text) ? text.GetString() ?? "Engine request failed" : "Engine request failed"));
                else if (root.TryGetProperty("result", out var result)) completion.TrySetResult(result.Clone());
                else completion.TrySetException(new InvalidDataException("Engine response has no result"));
            }
        }
        catch (Exception error) { failure = error; }
        finally { receiveFailure = failure; foreach (var (id, completion) in pending) if (pending.TryRemove(id, out _)) completion.TrySetException(failure); }
    }

    internal async Task<T> CallAsync<T>(string method, CancellationToken token)
    {
        if (disconnected || receiveFailure is not null || engine.HasExited) throw new EndOfStreamException("The authenticated engine disconnected");
        long id = Interlocked.Increment(ref nextId);
        var completion = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!pending.TryAdd(id, completion)) throw new InvalidOperationException("Duplicate engine request identity");
        try
        {
            byte[] request = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { jsonrpc = "2.0", id, method }) + "\n");
            await writes.WaitAsync(token);
            try { await pipe.WriteAsync(request, token); await pipe.FlushAsync(token); }
            finally { writes.Release(); }
            var result = await completion.Task.WaitAsync(token);
            return result.Deserialize<T>() ?? throw new InvalidDataException("Engine result is missing");
        }
        finally { pending.TryRemove(id, out _); }
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
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        try { await engine.WaitForExitAsync(deadline.Token); }
        catch (OperationCanceledException) { throw new IOException("Engine cleanup is still pending; do not reboot"); }
        engine.Dispose();
    }
}
