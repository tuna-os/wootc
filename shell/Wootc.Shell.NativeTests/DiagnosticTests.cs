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
}
