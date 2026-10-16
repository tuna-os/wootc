using System.Text.Json;
using System.Text.Json.Nodes;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

// The goldens are the engine's own bytes (app/status_install_recovery_test.go).
public sealed class InstallRecoveryProtocolTests
{
    private static string Golden(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "install-recovery", name));

    private static InstallRecoverySummary Decode(string json)
    {
        using var document = JsonDocument.Parse(json);
        return NativeProtocol.DecodeStartup<InstallRecoverySummary>("GetInstallRecovery", document.RootElement);
    }

    private static string Mutate(string name, Action<JsonObject> change)
    {
        var node = JsonNode.Parse(Golden(name))!.AsObject();
        change(node);
        return node.ToJsonString();
    }

    [Fact]
    public void EngineGoldensDecodeAndRoute()
    {
        var interrupted = Decode(Golden("interrupted.json"));
        Assert.Equal(("resumable", "interrupted", "resume", true), (interrupted.Class, interrupted.Cause, interrupted.Recommended, interrupted.Actions.ResumeInstall));
        Assert.Equal("Setup stopped unexpectedly", interrupted.Title);
        Assert.Equal(StartupRoute.Interrupted, StartupController.SelectRoute(new(new InstallStatus { Existing = true }, new RecoveryVerdict(), new LifecycleState { State = "staged" }, interrupted)));
        var none = Decode(Golden("none.json"));
        Assert.Equal("none", none.Class);
        Assert.Equal(StartupRoute.Assessment, StartupController.SelectRoute(new(new InstallStatus(), new RecoveryVerdict(), new LifecycleState(), none)));
        Assert.Equal("rpc-install", NativeEngineSession.RpcStage("GetInstallRecovery"));
    }

    public static TheoryData<string> Refused() => new()
    {
        Mutate("interrupted.json", node => node["evidence"] = new JsonArray("journal.json: C:\\private")),
        Mutate("interrupted.json", node => node["error"] = "C:\\private"),
        Mutate("interrupted.json", node => node["observation"] = new JsonObject()),
        Mutate("interrupted.json", node => node.Remove("recommended")),
        Mutate("interrupted.json", node => node["class"] = "healthy"),
        Mutate("interrupted.json", node => node["cause"] = "C:\\private"),
        Mutate("interrupted.json", node => node["recommended"] = "format-disk"),
        Mutate("interrupted.json", node => node["title"] = ""),
        Mutate("interrupted.json", node => node["message"] = new string('x', 513)),
        Mutate("interrupted.json", node => node["keepsVerifiedBytes"] = -1),
        Mutate("interrupted.json", node => node["actions"] = new JsonObject { ["resumeInstall"] = false, ["retryDeploy"] = false, ["repairBoot"] = false, ["remove"] = false }),
        Mutate("interrupted.json", node => node["actions"]!.AsObject()["extra"] = true),
        Mutate("interrupted.json", node => node["discardsRootDisk"] = "false"),
        Mutate("none.json", node => node["actions"]!.AsObject()["remove"] = true),
        Mutate("none.json", node => node["title"] = "Linux is installed"),
        Golden("interrupted.json").Replace("\"class\":\"resumable\"", "\"class\":\"none\",\"class\":\"resumable\""),
    };

    [Theory]
    [MemberData(nameof(Refused))]
    public void MalformedOrLeakySummariesAreRefused(string json) =>
        Assert.Throws<InvalidDataException>(() => Decode(json));
}
