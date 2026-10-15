using System.Text.Json;
using System.Text.Json.Serialization;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Native;

internal static class NativeProtocol
{
    internal sealed class Handshake
    {
        [JsonPropertyName("kind")] public string Kind { get; set; } = "";
        [JsonPropertyName("protocolVersion")] public int ProtocolVersion { get; set; }
        [JsonPropertyName("session")] public string Session { get; set; } = "";
        [JsonPropertyName("buildId")] public string BuildId { get; set; } = "";
        [JsonPropertyName("brandId")] public string BrandId { get; set; } = "";
    }

    internal static JsonDocument ParseObject(ReadOnlyMemory<byte> bytes)
    {
        var document = JsonDocument.Parse(bytes);
        try
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Native frame must be an object");
            RejectDuplicates(document.RootElement);
            return document;
        }
        catch { document.Dispose(); throw; }
    }
    private static void RejectDuplicates(JsonElement element)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            var keys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in element.EnumerateObject())
            {
                if (!keys.Add(property.Name)) throw new InvalidDataException("Native frame has duplicate properties");
                RejectDuplicates(property.Value);
            }
        }
        else if (element.ValueKind == JsonValueKind.Array) foreach (var value in element.EnumerateArray()) RejectDuplicates(value);
    }

    internal static void ValidateReady(byte[] bytes, Handshake hello)
    {
        using var document = ParseObject(bytes);
        var ready = document.RootElement.Deserialize<Handshake>(new JsonSerializerOptions { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow });
        if (ready is null || ready.Kind != "ready" || ready.ProtocolVersion != 1 || ready.Session != hello.Session || ready.BuildId != hello.BuildId || ready.BrandId != hello.BrandId)
            throw new InvalidDataException("The engine acknowledgement differs from this session package");
    }

    // Six ordered, package-bound progress records are the entire startup trace.
    internal sealed class StartupProgress
    {
        private int next;
        internal string LastPhase { get; private set; } = "none";
        private static JsonDocument ParseStartupObject(byte[] bytes)
        {
            try { return ParseObject(bytes); }
            catch (JsonException) { throw new InvalidDataException("Invalid engine startup frame"); }
        }
        internal bool Accept(byte[] bytes, Handshake hello)
        {
            using var document = ParseStartupObject(bytes);
            var root = document.RootElement;
            if (!root.TryGetProperty("kind", out var kind) || kind.ValueKind != JsonValueKind.String)
                throw new InvalidDataException("Startup frame lacks a kind");
            if (kind.GetString() == "ready")
            {
                if (next != 6) throw new InvalidDataException("Ready precedes dispatcher preparation");
                ValidateReady(bytes, hello);
                next++;
                return true;
            }
            string[] fields = { "kind", "protocolVersion", "session", "buildId", "brandId", "phase", "outcome" };
            if (root.EnumerateObject().Count() != fields.Length || fields.Any(field => !root.TryGetProperty(field, out _)))
                throw new InvalidDataException("Unexpected startup frame fields");
            Require(root, "protocolVersion", JsonValueKind.Number);
            foreach (string field in fields.Where(field => field != "protocolVersion")) Require(root, field, JsonValueKind.String);
            if (kind.GetString() != "startup" || (!root.GetProperty("protocolVersion").TryGetInt32(out int version) || version != 1) ||
                root.GetProperty("session").GetString() != hello.Session || root.GetProperty("buildId").GetString() != hello.BuildId || root.GetProperty("brandId").GetString() != hello.BrandId || next >= 6)
                throw new InvalidDataException("Startup frame differs from the authenticated package");
            string expected = new[] { "selection", "application", "dispatcher" }[next / 2];
            string outcome = root.GetProperty("outcome").GetString()!;
            if (root.GetProperty("phase").GetString() != expected ||
                (outcome != (next % 2 == 0 ? "begin" : "complete") && !(next % 2 == 1 && outcome == "failed")))
                throw new InvalidDataException("Startup progress is out of order");
            LastPhase = "startup-" + expected;
            if (outcome == "failed") throw new IOException("Engine startup phase refused");
            next++;
            return false;
        }
    }

    internal static async Task ReadStartupAsync(Stream pipe, Handshake hello, Action<string> observe, CancellationToken token)
    {
        var progress = new StartupProgress();
        try
        {
            while (true)
            {
                byte[] line = await NativeEngineSession.ReadLineAsync(pipe, 16384, token);
                if (progress.Accept(line, hello)) return;
                observe(progress.LastPhase);
            }
        }
        catch
        {
            if (progress.LastPhase != "none") observe(progress.LastPhase);
            throw;
        }
    }

    private static void Require(JsonElement result, string property, JsonValueKind type)
    {
        if (!result.TryGetProperty(property, out var value) || (type == JsonValueKind.True ? value.ValueKind is not (JsonValueKind.True or JsonValueKind.False) : value.ValueKind != type))
            throw new InvalidDataException("The engine omitted or mistyped a required startup observation");
    }
    private static void OptionalString(JsonElement result, string property)
    {
        if (result.TryGetProperty(property, out var value) && value.ValueKind != JsonValueKind.String)
            throw new InvalidDataException("The engine mistyped an optional startup observation");
    }

    private static readonly string[] InstallRecoveryFields = ["class", "cause", "imageRef", "lastCompletedStep", "stoppedAtStep", "title", "message", "recommended", "actions", "discardsRootDisk", "keepsVerifiedBlobs", "keepsVerifiedBytes"];
    private static readonly string[] InstallRecoveryActionFields = ["resumeInstall", "retryDeploy", "repairBoot", "remove"];

    // The summary has a fixed field set: evidence lines, the step error and the
    // raw observation never cross the pipe, so their presence is a refusal.
    private static void DecodeInstallRecovery(JsonElement result)
    {
        if (result.EnumerateObject().Count() != InstallRecoveryFields.Length || InstallRecoveryFields.Any(field => !result.TryGetProperty(field, out _)))
            throw new InvalidDataException("Install recovery payload has an unsupported field set");
        foreach (string field in new[] { "class", "cause", "imageRef", "lastCompletedStep", "stoppedAtStep", "title", "message", "recommended" })
        {
            Require(result, field, JsonValueKind.String);
            if (result.GetProperty(field).GetString()!.Length > 512) throw new InvalidDataException("Install recovery text exceeds its bound");
        }
        Require(result, "discardsRootDisk", JsonValueKind.True);
        if (!result.GetProperty("keepsVerifiedBlobs").TryGetInt32(out int blobs) || blobs < 0 ||
            !result.GetProperty("keepsVerifiedBytes").TryGetInt64(out long bytes) || bytes < 0)
            throw new InvalidDataException("Install recovery counts are invalid");
        var actions = result.GetProperty("actions");
        if (actions.ValueKind != JsonValueKind.Object || actions.EnumerateObject().Count() != InstallRecoveryActionFields.Length)
            throw new InvalidDataException("Install recovery actions have an unsupported field set");
        RejectDuplicates(actions);
        foreach (string field in InstallRecoveryActionFields) Require(actions, field, JsonValueKind.True);
        string Text(string field) => result.GetProperty(field).GetString()!;
        string recoveryClass = Text("class");
        if (recoveryClass is not ("none" or "complete" or "in-progress" or "resumable" or "failed" or "needs-repair") ||
            Text("cause") is not ("" or "cancelled" or "interrupted" or "step-failed" or "never-booted" or "deployer-interrupted" or "deployer-failed" or "awaiting-restart" or "deployed" or "healthy" or "unknown") ||
            Text("recommended") is not ("" or "resume" or "retry-deploy" or "repair-boot" or "remove"))
            throw new InvalidDataException("Install recovery classification is unsupported");
        bool anyAction = InstallRecoveryActionFields.Any(field => actions.GetProperty(field).GetBoolean());
        if (recoveryClass == "none" && (anyAction || Text("title").Length != 0 || Text("message").Length != 0))
            throw new InvalidDataException("An absent install attempt cannot carry recovery actions");
        if (recoveryClass is "resumable" or "failed" or "needs-repair" && (Text("title").Length == 0 || Text("message").Length == 0 || !anyAction))
            throw new InvalidDataException("An interrupted install needs engine text and a safe action");
    }

    private static readonly string[] InstallGrantFields = ["schemaVersion", "session", "brandId", "intentId", "imageRef", "storageDrive", "diskSizeGB", "encryption", "bitLockerOn", "bitLockerRecoveryKeyWarning", "fastStartupOn", "secureBootChainWarning"];

    internal static T DecodeResult<T>(string method, JsonElement result, string? expectedBrand)
    {
        switch (method)
        {
            case "PrepareNativeInstall":
                return (T)(object)DecodeInstallGrant(result, expectedBrand);
            case "ConfirmNativeInstall" or "CancelInstall" or "Reboot":
                if (result.ValueKind != JsonValueKind.Null) throw new InvalidDataException("Install action returned an unexpected result");
                return default!;
            default:
                return DecodeStartup<T>(method, result);
        }
    }

    // A grant names one session, brand and single-use intent, and the plan the
    // person confirms. Anything outside that exact shape is refused.
    internal static NativeInstallGrant DecodeInstallGrant(JsonElement result, string? expectedBrand)
    {
        if (result.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Install grant must be an object");
        RejectDuplicates(result);
        if (result.EnumerateObject().Count() != InstallGrantFields.Length || InstallGrantFields.Any(field => !result.TryGetProperty(field, out _)))
            throw new InvalidDataException("Install grant has an unsupported field set");
        foreach (string field in new[] { "session", "brandId", "intentId", "imageRef", "storageDrive", "encryption", "secureBootChainWarning" }) Require(result, field, JsonValueKind.String);
        foreach (string field in new[] { "bitLockerOn", "bitLockerRecoveryKeyWarning", "fastStartupOn" }) Require(result, field, JsonValueKind.True);
        string Text(string field) => result.GetProperty(field).GetString()!;
        if (!result.GetProperty("schemaVersion").TryGetInt32(out int schema) || schema != 1 ||
            !result.GetProperty("diskSizeGB").TryGetInt32(out int size) || size is < 20 or > 2048 ||
            !ProtectedPackage.LowerHex(Text("session"), 32) || !ProtectedPackage.LowerHex(Text("intentId"), 32) ||
            expectedBrand is null || Text("brandId") != expectedBrand ||
            Text("imageRef").Length is 0 or > 512 || Text("storageDrive").Length != 1 || Text("storageDrive")[0] is < 'A' or > 'Z' ||
            Text("encryption") is not ("none" or "luks-passphrase") || Text("secureBootChainWarning").Length > 1024)
            throw new InvalidDataException("Install grant is invalid");
        return result.Deserialize<NativeInstallGrant>() ?? throw new InvalidDataException("Install grant is missing");
    }

    private static readonly HashSet<string> ProgressFields = new(StringComparer.Ordinal) { "phaseId", "step", "message", "percent", "done", "error" };

    // One install:progress event: the engine's ProgressEvent fields only, each
    // once, bounded, with a finite percent. Step IDs are matched, never trusted
    // as labels; the view looks labels up in the engine's catalogue.
    internal static ProgressEvent DecodeProgress(JsonElement update)
    {
        if (update.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Install progress must be an object");
        RejectDuplicates(update);
        if (update.EnumerateObject().Any(property => !ProgressFields.Contains(property.Name)))
            throw new InvalidDataException("Install progress has an unsupported field");
        foreach (string field in new[] { "step", "message" }) Require(update, field, JsonValueKind.String);
        Require(update, "done", JsonValueKind.True);
        OptionalString(update, "phaseId"); OptionalString(update, "error");
        if (!update.TryGetProperty("percent", out var percent) || percent.ValueKind != JsonValueKind.Number || !percent.TryGetDouble(out double value) || !double.IsFinite(value))
            throw new InvalidDataException("Install progress percent is invalid");
        foreach (var (field, limit) in new[] { ("phaseId", 256), ("step", 256), ("message", 4096), ("error", 4096) })
            if (update.TryGetProperty(field, out var text) && text.GetString()!.Length > limit) throw new InvalidDataException("Install progress text exceeds its bound");
        return update.Deserialize<ProgressEvent>() ?? throw new InvalidDataException("Install progress is missing");
    }

    internal static T DecodeStartup<T>(string method, JsonElement result)
    {
        if (result.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Startup result must be an object");
        RejectDuplicates(result);
        switch (method)
        {
            case "GetStatus":
                foreach (string field in new[] { "running", "done", "existing" }) Require(result, field, JsonValueKind.True);
                OptionalString(result, "error");
                break;
            case "GetLastRun":
                foreach (string field in new[] { "state", "updatedAt", "updatedBy" }) Require(result, field, JsonValueKind.String);
                if (result.TryGetProperty("verdict", out _)) throw new InvalidDataException("Lifecycle payload contains a recovery verdict");
                OptionalString(result, "phase"); OptionalString(result, "phaseId"); OptionalString(result, "error");
                break;
            case "GetRecoveryVerdict":
                foreach (string field in new[] { "verdict", "title", "message", "timestamp" }) Require(result, field, JsonValueKind.String);
                foreach (string field in new[] { "untouched", "canTryAgain", "canRemove", "canRepairBoot" }) Require(result, field, JsonValueKind.True);
                if (result.TryGetProperty("state", out _)) throw new InvalidDataException("Recovery payload contains a lifecycle state");
                OptionalString(result, "phase"); OptionalString(result, "phaseId"); OptionalString(result, "details");
                if (result.TryGetProperty("logTail", out var tail) && (tail.ValueKind != JsonValueKind.Array || tail.EnumerateArray().Any(item => item.ValueKind != JsonValueKind.String)))
                    throw new InvalidDataException("Recovery log tail is not a string array");
                break;
            case "GetInstallRecovery":
                DecodeInstallRecovery(result);
                break;
            default: throw new InvalidDataException("Unsupported native startup method");
        }
        return result.Deserialize<T>() ?? throw new InvalidDataException("Engine startup result is missing");
    }
}
