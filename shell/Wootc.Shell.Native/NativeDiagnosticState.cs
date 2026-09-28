using System.Diagnostics;

namespace Wootc.Shell.Native;

// One fixed primary failure survives later cleanup observations. This is not
// a trace, and never incorporates exception messages or arbitrary method text.
internal enum NativeCleanupObservation { None, Pending, EngineExited }

internal sealed class NativeDiagnosticState
{
    private string? primaryRpcFailure;
    private string? primaryStartupFailure;
    private readonly object gate = new();
    private NativeCleanupObservation cleanup;
    private Process? observedEngine;
    private int? observedExitCode;

    internal string Project(string stage, Exception? error, Process? engine)
    {
        stage = SafeStage(stage);
        string failure = NativeEngineConnector.DescribeFailure(error);
        lock (gate)
        {
            string process="not-launched";
            bool actualExited=false;
            if(engine is not null)
            {
                if(ReferenceEquals(engine,observedEngine) && observedExitCode is int knownExit)
                {actualExited=true;process=$"exited:{knownExit}";}
                else
                {
                    try
                    {
                        actualExited=engine.HasExited;
                        if(actualExited){observedEngine=engine;observedExitCode=engine.ExitCode;process=$"exited:{observedExitCode}";}
                        else process="retained-running";
                    }
                    catch(InvalidOperationException){process="unavailable";}
                }
                if((stage is "session-cleanup-exited" or "cleanup-exited") && actualExited)
                    cleanup=NativeCleanupObservation.EngineExited;
                else if(cleanup!=NativeCleanupObservation.EngineExited && (stage is "session-cleanup-wait" or "session-cleanup-pending" or "cleanup-pending") && process=="retained-running")
                    cleanup=NativeCleanupObservation.Pending;
            }
            string cleanupText=cleanup switch {NativeCleanupObservation.EngineExited=>"engine-exited",NativeCleanupObservation.Pending=>"pending",_=>"none"};
            if (error is not null && stage.StartsWith("rpc-", StringComparison.Ordinal))
                primaryRpcFailure ??= $"{stage}; {failure}" + (error is StorageObservationFailure storage ? $"; {storage.Projection}" : "");
            if (error is not null && stage.StartsWith("startup-", StringComparison.Ordinal))
                primaryStartupFailure ??= $"{stage}; {failure}";
            return $"Stage:{stage}; {failure}; Engine:{process}; Cleanup:{cleanupText}; PrimaryRpc:{primaryRpcFailure ?? "none"}; PrimaryStartup:{primaryStartupFailure ?? "none"}";
        }
    }

    private static string SafeStage(string stage) => stage switch
    {
        "startup-selection" or "startup-application" or "startup-dispatcher" or
        "package" or "launch" or "pipe-open" or "peer" or "hello-ready" or "authenticated" or
        "cleanup-pending" or "cleanup-exited" or "session-cleanup-wait" or
        "session-cleanup-pending" or "session-cleanup-exited" or
        "rpc-status-request" or "rpc-status-response" or "rpc-status-decode" or "rpc-status-complete" or
        "rpc-lifecycle-request" or "rpc-lifecycle-response" or "rpc-lifecycle-decode" or "rpc-lifecycle-complete" or
        "rpc-recovery-request" or "rpc-recovery-response" or "rpc-recovery-decode" or "rpc-recovery-complete" or
        "rpc-configuration-request" or "rpc-configuration-response" or "rpc-configuration-decode" or "rpc-configuration-complete" or
        "rpc-other-request" or "rpc-other-response" or "rpc-other-decode" or "rpc-other-complete" => stage,
        _ => "unknown"
    };
}
