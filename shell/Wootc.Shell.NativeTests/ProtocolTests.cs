using System.Text;
using System.Text.Json;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

public sealed class ProtocolTests
{
    [Theory]
    [InlineData("session")]
    [InlineData("buildId")]
    [InlineData("brandId")]
    public void ReadyRejectsDuplicateIdentityEvenWhenLastValueMatches(string field)
    {
        var hello = new NativeProtocol.Handshake { Kind = "hello", ProtocolVersion = 1, Session = new string('a', 32), BuildId = new string('b', 40), BrandId = "wootc" };
        string valid = JsonSerializer.Serialize(new NativeProtocol.Handshake { Kind = "ready", ProtocolVersion = 1, Session = hello.Session, BuildId = hello.BuildId, BrandId = hello.BrandId });
        NativeProtocol.ValidateReady(Encoding.UTF8.GetBytes(valid), hello);
        string duplicate = "{\"" + field + "\":\"wrong-first-value\"," + valid[1..];
        Assert.Throws<InvalidDataException>(() => NativeProtocol.ValidateReady(Encoding.UTF8.GetBytes(duplicate), hello));
        Assert.Throws<InvalidDataException>(() => NativeProtocol.ValidateReady(Encoding.UTF8.GetBytes(valid[..^1] + ",\"" + field + "\":\"wrong-last-value\"}"), hello));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"running\":false,\"done\":false}")]
    [InlineData("{\"running\":false,\"done\":false,\"existing\":null}")]
    [InlineData("{\"running\":false,\"done\":false,\"existing\":\"false\"}")]
    [InlineData("{\"running\":true,\"running\":false,\"done\":false,\"existing\":false}")]
    public void MissingOrAmbiguousStatusCannotBecomeFreshRoute(string json)
    {
        using var document = JsonDocument.Parse(json);
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeStartup<InstallStatus>("GetStatus", document.RootElement));
    }

    [Fact]
    public void ActualEmptyGettersAllowFreshOnlyWithCompleteStatusObservations()
    {
        using var status = JsonDocument.Parse("{\"running\":false,\"done\":false,\"existing\":false}");
        using var lifecycle = JsonDocument.Parse("{\"state\":\"\",\"updatedAt\":\"\",\"updatedBy\":\"\"}");
        using var recovery = JsonDocument.Parse("{\"verdict\":\"\",\"title\":\"\",\"message\":\"\",\"untouched\":false,\"canTryAgain\":false,\"canRemove\":false,\"canRepairBoot\":false,\"timestamp\":\"\"}");
        var snapshot = new StartupSnapshot(NativeProtocol.DecodeStartup<InstallStatus>("GetStatus", status.RootElement), NativeProtocol.DecodeStartup<RecoveryVerdict>("GetRecoveryVerdict", recovery.RootElement), NativeProtocol.DecodeStartup<LifecycleState>("GetLastRun", lifecycle.RootElement));
        Assert.Equal(StartupRoute.Assessment, StartupController.SelectRoute(snapshot));
        using var empty = JsonDocument.Parse("{}");
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeStartup<LifecycleState>("GetLastRun", empty.RootElement));
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeStartup<RecoveryVerdict>("GetRecoveryVerdict", empty.RootElement));
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeStartup<LifecycleState>("GetLastRun", recovery.RootElement));
        Assert.Throws<InvalidDataException>(() => NativeProtocol.DecodeStartup<RecoveryVerdict>("GetRecoveryVerdict", lifecycle.RootElement));
    }

    [Fact]
    public void RpcFrameRejectsDuplicateOutcomeAndNestedStatus()
    {
        foreach (string json in new[] { "{\"jsonrpc\":\"2.0\",\"id\":1,\"id\":1,\"result\":{}}", "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"existing\":true,\"existing\":false}}" })
            Assert.Throws<InvalidDataException>(() => NativeProtocol.ParseObject(Encoding.UTF8.GetBytes(json)));
    }
}
