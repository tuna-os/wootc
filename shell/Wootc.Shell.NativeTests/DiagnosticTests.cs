using System.ComponentModel;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

public sealed class DiagnosticTests
{
    [Theory]
    [InlineData("GetStatus", "rpc-status")]
    [InlineData("GetLastRun", "rpc-lifecycle")]
    [InlineData("GetRecoveryVerdict", "rpc-recovery")]
    [InlineData("111111-111111-111111-111111-111111-111111-111111-111111", "rpc-other")]
    public void RpcStageOnlyProjectsKnownStartupMethods(string method, string expected) =>
        Assert.Equal(expected, NativeEngineSession.RpcStage(method));

    [Fact]
    public void LatestCleanupProjectionRetainsOnlyBoundedWhitelistedPrimaryFailure()
    {
        const string publicSecret = "111111-111111-111111-111111-111111-111111-111111-111111";
        var state = new NativeDiagnosticState();
        state.Project("rpc-status-response", new OperationCanceledException(publicSecret), null);
        string latest = state.Project("session-cleanup-exited", null, null);
        Assert.Contains("PrimaryRpc:rpc-status-response; Failure:deadline", latest);
        Assert.DoesNotContain(publicSecret, latest);
        for (int index = 0; index < 100; index++)
            latest = state.Project(publicSecret, new Exception(publicSecret), null);
        Assert.Contains("Stage:unknown", latest);
        Assert.Contains("PrimaryRpc:rpc-status-response; Failure:deadline", latest);
        Assert.DoesNotContain(publicSecret, latest);
        Assert.InRange(latest.Length, 1, 299);
    }

    [Fact]
    public async Task ActualEngineExitCleanupSurvivesDisposedProcessAndLateRpcFailure()
    {
        var state=new NativeDiagnosticState();
        using var process=System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(Path.Combine(Environment.SystemDirectory,"cmd.exe"),"/c exit 0") {UseShellExecute=false,CreateNoWindow=true})!;
        using var deadline=new CancellationTokenSource(TimeSpan.FromSeconds(5));
        await process.WaitForExitAsync(deadline.Token);
        Assert.Equal(0,process.ExitCode);
        string completed=state.Project("session-cleanup-exited",null,process);
        Assert.Contains("Cleanup:engine-exited",completed);
        process.Dispose();
        string latest=state.Project("rpc-configuration-response",new OperationCanceledException("public synthetic message"),process);
        Assert.Contains("Stage:rpc-configuration-response",latest);
        Assert.Contains("Cleanup:engine-exited",latest);
        Assert.Contains("Engine:exited:0",latest);
        Assert.Contains("PrimaryRpc:rpc-configuration-response",latest);
        Assert.DoesNotContain("public synthetic message",latest);
        Assert.Contains("Cleanup:none",new NativeDiagnosticState().Project("session-cleanup-exited",null,null));
    }

    [Fact]
    public void LateOldSessionAndQueuedDeliveryCannotReplaceNewConnectionDiagnostic()
    {
        var delivered = new List<NativeDiagnosticObservation>();
        var connector = new NativeEngineConnector("unused protected package path", delivered.Add);
        var old = connector.BeginObservation();
        old("rpc-configuration-request", null, null);
        var queuedOld = Assert.Single(delivered);
        var current = connector.BeginObservation();
        current("authenticated", null, null);
        var latest = delivered.Last();
        old("rpc-configuration-response", new OperationCanceledException(), null);
        old("session-cleanup-exited", null, null);
        Assert.Equal(2, delivered.Count);
        Assert.False(queuedOld.IsCurrent());
        Assert.True(latest.IsCurrent());
        Assert.Contains("Stage:authenticated", latest.Projection);
        Assert.Contains("PrimaryRpc:none", latest.Projection);
        Assert.Contains("Cleanup:none", latest.Projection);
    }

    [Fact]
    public void FailureProjectionRetainsNumericClassAndExcludesExceptionMessages()
    {
        const string publicSecret = "111111-111111-111111-111111-111111-111111-111111-111111";
        var error = new Win32Exception(5, publicSecret);
        string projection = NativeEngineConnector.DescribeFailure(error);
        Assert.Contains("Failure:win32", projection);
        Assert.Contains("NativeCode:5", projection);
        Assert.Contains($"HResult:{error.HResult}", projection);
        Assert.DoesNotContain(publicSecret, projection);
        Assert.Equal("Failure:deadline; HResult:-2146233029; NativeCode:0", NativeEngineConnector.DescribeFailure(new OperationCanceledException(publicSecret)));
        Assert.DoesNotContain(publicSecret, NativeEngineConnector.DescribeFailure(new Exception(publicSecret)));
    }

    internal const string StorageDiagnostic = """
    {"callPhase":"standalone-query","callMilliseconds":10000,"phaseTimings":{"root-enumeration":0,"initial-selection":0,"storage-first-query":10000,"storage-capacity":0,"metadata-read":0,"metadata-root-audit":0,"catalogue-policy":0,"metadata-revalidation":0,"storage-second-query":0,"storage-identity-reread":0,"final-selection":0},"schemaVersion":1,"kind":"storage-observation","phase":"import-storage","auditStage":"complete","contextState":"deadline","commandAttempted":true,"commandStarted":true,"waitCompleted":true,"commandPid":100,"exitCode":1,"deadlineExceeded":true,"auditMilliseconds":12,"commandMilliseconds":9988}
    """;

    [Fact]
    public void StrictStorageFailureProjectionRejectsAmbiguityAndKeepsNoRawText()
    {
        using var valid=System.Text.Json.JsonDocument.Parse(StorageDiagnostic);
        var failure=StorageObservationFailure.Decode(valid.RootElement);
        var state=new NativeDiagnosticState();
        state.Project("rpc-configuration-response",failure,null);
        string latest=state.Project("session-cleanup-exited",null,null);
        Assert.Contains("StoragePhase:import-storage",latest);
        Assert.Contains("CommandMs:9988",latest);
        foreach (string invalid in new[]{
            StorageDiagnostic.Replace("\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1"),
            StorageDiagnostic.Replace("\"kind\":", "\"Kind\":"),
            StorageDiagnostic.Replace("import-storage","private-path-secret"),
            StorageDiagnostic.Replace("\"callPhase\":\"standalone-query\"", "\"callPhase\":\"private-path\""),
            StorageDiagnostic.Replace("\"callMilliseconds\":10000", "\"callMilliseconds\":9999"),
            StorageDiagnostic.Replace("\"root-enumeration\":0", "\"root-enumeration\":0,\"root-enumeration\":0"),
            StorageDiagnostic.Replace("\"root-enumeration\":0", "\"unknown-phase\":0"),
            StorageDiagnostic.Replace("\"deadlineExceeded\":true", "\"deadlineExceeded\":false"),
            StorageDiagnostic.Replace("\"auditMilliseconds\":12", "\"auditMilliseconds\":60000"),
            StorageDiagnostic.Replace("\"commandPid\":100", "\"commandPid\":-1"),
            StorageDiagnostic.Replace("\"commandStarted\":true", "\"commandStarted\":false"),
            StorageDiagnostic.Replace("\"auditMilliseconds\":12", "\"auditMilliseconds\":60001"),
            StorageDiagnostic.Replace("\"commandMilliseconds\":9988", "\"commandMilliseconds\":9223372036854775808"),
            StorageDiagnostic.Replace("\"contextState\":\"deadline\"", "\"contextState\":\"active\""),
            StorageDiagnostic.Replace("\"exitCode\":1", "\"exitCode\":\"secret\"")
        })
        {
            using var document=System.Text.Json.JsonDocument.Parse(invalid);
            Assert.ThrowsAny<Exception>(()=>StorageObservationFailure.Decode(document.RootElement));
        }
    }
}
