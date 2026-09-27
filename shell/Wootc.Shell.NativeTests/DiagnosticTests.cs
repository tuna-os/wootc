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
    {"schemaVersion":1,"kind":"storage-observation","phase":"import-storage","auditStage":"complete","contextState":"deadline","commandAttempted":true,"commandStarted":true,"waitCompleted":true,"commandPid":100,"exitCode":1,"deadlineExceeded":true,"auditMilliseconds":12,"commandMilliseconds":9988}
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
