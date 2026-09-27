using System.Diagnostics;

namespace Wootc.Shell.Native;

// One fixed primary failure survives later cleanup observations. This is not
// a trace, and never incorporates exception messages or arbitrary method text.
internal sealed class NativeDiagnosticState
{
    private string? primaryRpcFailure;
    private readonly object gate = new();

    internal string Project(string stage, Exception? error, Process? engine)
    {
        stage = SafeStage(stage);
        string failure = NativeEngineConnector.DescribeFailure(error);
        string process = engine is null ? "not-launched" : engine.HasExited ? $"exited:{engine.ExitCode}" : "retained-running";
        lock (gate)
        {
            if (error is not null && stage.StartsWith("rpc-", StringComparison.Ordinal))
                primaryRpcFailure ??= $"{stage}; {failure}";
            return $"Stage:{stage}; {failure}; Engine:{process}; PrimaryRpc:{primaryRpcFailure ?? "none"}";
        }
    }

    private static string SafeStage(string stage) => stage switch
    {
        "package" or "launch" or "pipe-open" or "peer" or "hello-ready" or "authenticated" or
        "cleanup-pending" or "cleanup-exited" or "session-cleanup-wait" or
        "session-cleanup-pending" or "session-cleanup-exited" or
        "rpc-status-request" or "rpc-status-response" or "rpc-status-decode" or "rpc-status-complete" or
        "rpc-lifecycle-request" or "rpc-lifecycle-response" or "rpc-lifecycle-decode" or "rpc-lifecycle-complete" or
        "rpc-recovery-request" or "rpc-recovery-response" or "rpc-recovery-decode" or "rpc-recovery-complete" or
        "rpc-other-request" or "rpc-other-response" or "rpc-other-decode" or "rpc-other-complete" => stage,
        _ => "unknown"
    };
}
