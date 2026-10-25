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
            case "PrepareNativeMaintenance":
                return (T)(object)DecodeMaintenanceGrant(result, expectedBrand);
            case "GetNativeInstallSpace":
                return (T)(object)DecodeInstallSpace(result);
            case "GetUninstallInfo":
                return (T)(object)DecodeUninstallInfo(result);
            case "InspectBoot":
                return (T)(object)DecodeBootReport(result);
            case "GetNativeVMStatus":
                return (T)(object)DecodeVMStatus(result);
            case "PrepareNativeVMAction":
                return (T)(object)DecodeVMGrant(result, expectedBrand);
            case "E2EDriveDirective":
                // The engine returns the raw directive (at most 16 KiB) or "".
                if (result.ValueKind != JsonValueKind.String || System.Text.Encoding.UTF8.GetByteCount(result.GetString()!) > Wootc.Shell.Core.E2EDriveDirective.MaximumBytes)
                    throw new InvalidDataException("Drive directive result is invalid");
                return (T)(object)result.GetString()!;
            case "E2EDriveReport" or "E2EDriveReady":
                if (result.ValueKind != JsonValueKind.Null) throw new InvalidDataException("Drive report returned an unexpected result");
                return default!;
            case "ConfirmNativeInstall" or "CancelInstall" or "Reboot" or "ConfirmNativeMaintenance" or "ConfirmNativeVMAction":
                if (result.ValueKind != JsonValueKind.Null) throw new InvalidDataException("Install action returned an unexpected result");
                return default!;
            default:
                return DecodeStartup<T>(method, result);
        }
    }

    private static readonly string[] InstallSpaceFields = { "imageRef", "compressedBytes", "sizeSource", "scratchGiB", "bundleGiB", "reserveGiB" };

    // The engine's InstallSpace, exactly: its reserve is what the form keeps
    // free beside the Linux disk, so a reserve below the smallest image's or
    // one that is not the sum of its parts is refused.
    internal static InstallSpace DecodeInstallSpace(JsonElement result)
    {
        if (result.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Install space must be an object");
        RejectDuplicates(result);
        if (result.EnumerateObject().Count() != InstallSpaceFields.Length || InstallSpaceFields.Any(field => !result.TryGetProperty(field, out _)))
            throw new InvalidDataException("Install space has an unsupported field set");
        Require(result, "imageRef", JsonValueKind.String);
        Require(result, "sizeSource", JsonValueKind.String);
        foreach (string field in new[] { "compressedBytes", "scratchGiB", "bundleGiB", "reserveGiB" }) Require(result, field, JsonValueKind.Number);
        var space = new InstallSpace
        {
            ImageRef = result.GetProperty("imageRef").GetString()!, SizeSource = result.GetProperty("sizeSource").GetString()!,
            CompressedBytes = result.GetProperty("compressedBytes").GetInt64(), ScratchGiB = result.GetProperty("scratchGiB").GetInt32(),
            BundleGiB = result.GetProperty("bundleGiB").GetInt32(), ReserveGiB = result.GetProperty("reserveGiB").GetInt32(),
        };
        if (space.ImageRef.Length is 0 or > 512 || space.SizeSource is not ("bundle" or "registry" or "default") ||
            space.CompressedBytes < 0 || space.ScratchGiB < 20 || space.BundleGiB < 0 ||
            space.ReserveGiB < Wootc.Shell.Core.ConsumerConfiguration.MinimumInstallReserveGb || space.ReserveGiB > 4096 ||
            space.ReserveGiB != space.ScratchGiB + space.BundleGiB + 2)
            throw new InvalidDataException("Install space is outside its contract");
        return space;
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

    private static void Exactly(JsonElement result, string what, string[] required, string[] optional)
    {
        if (result.ValueKind != JsonValueKind.Object) throw new InvalidDataException(what + " must be an object");
        RejectDuplicates(result);
        var known = new HashSet<string>(required.Concat(optional), StringComparer.Ordinal);
        if (result.EnumerateObject().Any(property => !known.Contains(property.Name)) || required.Any(field => !result.TryGetProperty(field, out _)))
            throw new InvalidDataException(what + " has an unsupported field set");
    }

    private static void BoundedText(JsonElement result, string field, int limit, bool optional = false)
    {
        if (optional && !result.TryGetProperty(field, out _)) return;
        Require(result, field, JsonValueKind.String);
        if (result.GetProperty(field).GetString()!.Length > limit) throw new InvalidDataException("Engine text exceeds its bound");
    }

    private static bool DriveLetter(string value) => value.Length == 0 || (value.Length == 1 && value[0] is >= 'A' and <= 'Z');

    private static readonly string[] MaintenanceActionNames = ["uninstall", "repair-boot", "restore-windows-boot", "try-again", "boot-linux"];
    private static readonly string[] MaintenanceGrantFields = ["schemaVersion", "session", "brandId", "intentId", "action", "deleteRootDisk", "removePartition", "diskPath", "storageDrive", "volumeLabel", "orphaned", "bootState"];

    // A maintenance grant names one session, brand, single-use intent and
    // action, with the facts the engine observed for the confirmation.
    internal static NativeMaintenanceGrant DecodeMaintenanceGrant(JsonElement result, string? expectedBrand)
    {
        Exactly(result, "Maintenance grant", MaintenanceGrantFields, []);
        foreach (var (field, limit) in new[] { ("session", 32), ("brandId", 64), ("intentId", 32), ("action", 32), ("diskPath", 1024), ("storageDrive", 1), ("volumeLabel", 256), ("bootState", 64) }) BoundedText(result, field, limit);
        foreach (string field in new[] { "deleteRootDisk", "removePartition", "orphaned" }) Require(result, field, JsonValueKind.True);
        string Text(string field) => result.GetProperty(field).GetString()!;
        bool uninstall = Text("action") == "uninstall";
        if (!result.GetProperty("schemaVersion").TryGetInt32(out int schema) || schema != 1 ||
            !ProtectedPackage.LowerHex(Text("session"), 32) || !ProtectedPackage.LowerHex(Text("intentId"), 32) ||
            expectedBrand is null || Text("brandId") != expectedBrand || !MaintenanceActionNames.Contains(Text("action")) || !DriveLetter(Text("storageDrive")) ||
            (!uninstall && (result.GetProperty("deleteRootDisk").GetBoolean() || result.GetProperty("removePartition").GetBoolean())))
            throw new InvalidDataException("Maintenance grant is invalid");
        return result.Deserialize<NativeMaintenanceGrant>() ?? throw new InvalidDataException("Maintenance grant is missing");
    }

    private static readonly string[] FirstBootVerdicts = ["waiting", "verified", "mismatch", "invalid", "unverifiable"];

    // The verified first-boot summary the engine attaches to a deployed
    // installation (app/firstboot_evidence.go FirstBootAssessment): counts and
    // public facts only, never the record's Windows paths.
    private static void DecodeBootEvidence(JsonElement evidence)
    {
        Exactly(evidence, "First-boot summary", ["verdict", "message"],
            ["reason", "kernel", "imageRef", "imageDigest", "sourceImageRef", "bootId", "secureBoot", "bridge", "writtenAt"]);
        BoundedText(evidence, "verdict", 32); BoundedText(evidence, "message", 1024);
        foreach (var (field, limit) in new[] { ("reason", 1024), ("kernel", 128), ("imageRef", 512), ("imageDigest", 80), ("sourceImageRef", 512), ("bootId", 36), ("writtenAt", 64) })
            BoundedText(evidence, field, limit, optional: true);
        if (!FirstBootVerdicts.Contains(evidence.GetProperty("verdict").GetString()))
            throw new InvalidDataException("First-boot summary carries an unknown verdict");
        if (evidence.TryGetProperty("secureBoot", out _)) Require(evidence, "secureBoot", JsonValueKind.True);
        if (!evidence.TryGetProperty("bridge", out var bridge)) return;
        Exactly(bridge, "First-boot bridge summary", ["boundFolders", "matchedUsers", "bitlockerUnlocked"], []);
        Require(bridge, "bitlockerUnlocked", JsonValueKind.True);
        foreach (string field in new[] { "boundFolders", "matchedUsers" })
            if (!bridge.GetProperty(field).TryGetInt32(out int count) || count is < 0 or > 4096)
                throw new InvalidDataException("First-boot bridge summary carries an invalid count");
    }

    internal static UninstallInfo DecodeUninstallInfo(JsonElement result)
    {
        Exactly(result, "Installation details", ["found", "storageDrive", "diskPath", "diskSizeGB", "onDedicatedVol", "reclaimGB", "orphaned", "deployed", "bootPending"], ["partitionRemovalReason", "volumeLabel", "bootEvidence"]);
        foreach (string field in new[] { "found", "onDedicatedVol", "orphaned", "deployed", "bootPending" }) Require(result, field, JsonValueKind.True);
        if (result.TryGetProperty("bootEvidence", out var evidence)) DecodeBootEvidence(evidence);
        BoundedText(result, "storageDrive", 1); BoundedText(result, "diskPath", 1024);
        BoundedText(result, "partitionRemovalReason", 1024, optional: true); BoundedText(result, "volumeLabel", 256, optional: true);
        foreach (string field in new[] { "diskSizeGB", "reclaimGB" })
            if (result.GetProperty(field).ValueKind != JsonValueKind.Number || !result.GetProperty(field).TryGetDouble(out double value) || !double.IsFinite(value) || value < 0)
                throw new InvalidDataException("Installation details carry an invalid size");
        if (!DriveLetter(result.GetProperty("storageDrive").GetString()!)) throw new InvalidDataException("Installation details carry an invalid drive");
        return result.Deserialize<UninstallInfo>() ?? throw new InvalidDataException("Installation details are missing");
    }

    private static readonly string[] BootStates = ["windows-only", "one-shot-armed", "wootc-default", "wootc-listed", "foreign-next", "unknown"];

    internal static BootRepairReport DecodeBootReport(JsonElement result)
    {
        string[] lists = ["bootSequence", "displayOrder", "wootcEntries", "findings", "refusals"];
        Exactly(result, "Boot check", ["observedAt", "bootState", "ownership", "canRestoreWindows", "canRepairBoot", "recommended"], [.. lists, "lifecycleState", "bundlePath"]);
        foreach (var (field, limit) in new[] { ("observedAt", 64), ("bootState", 64), ("ownership", 64), ("recommended", 64) }) BoundedText(result, field, limit);
        BoundedText(result, "lifecycleState", 64, optional: true); BoundedText(result, "bundlePath", 1024, optional: true);
        foreach (string field in new[] { "canRestoreWindows", "canRepairBoot" }) Require(result, field, JsonValueKind.True);
        foreach (string field in lists)
        {
            if (!result.TryGetProperty(field, out var list)) continue;
            if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > 64 || list.EnumerateArray().Any(item => item.ValueKind != JsonValueKind.String || item.GetString()!.Length > 1024))
                throw new InvalidDataException("Boot check list is invalid");
        }
        if (!BootStates.Contains(result.GetProperty("bootState").GetString()) ||
            result.GetProperty("recommended").GetString() is not ("" or "none" or "restore-windows" or "repair-boot" or "manual"))
            throw new InvalidDataException("Boot check classification is unsupported");
        return result.Deserialize<BootRepairReport>() ?? throw new InvalidDataException("Boot check is missing");
    }

    private static readonly string[] VMPhases = ["absent", "preparing", "ready", "starting", "running", "stopping", "stopped", "needs_recovery", "failed", "unavailable"];
    private static readonly string[] VMActionNames = ["install-runtime", "prepare", "boot", "stop", "force-stop"];
    private static readonly string[] VMCapabilityFields = ["available", "reason", "accelerator", "runtimeNeeded"];

    private static void DecodeVMCapability(JsonElement capability)
    {
        Exactly(capability, "VM capability", VMCapabilityFields, []);
        Require(capability, "available", JsonValueKind.True); Require(capability, "runtimeNeeded", JsonValueKind.True);
        BoundedText(capability, "reason", 1024); BoundedText(capability, "accelerator", 64);
    }

    // The VM status is a projection: any path, process or run identity in it
    // is an unsupported field and refuses the frame.
    internal static NativeVMStatus DecodeVMStatus(JsonElement result)
    {
        Exactly(result, "VM status", ["schemaVersion", "phase", "image", "username", "desktopReady", "error", "launch", "prepare"], []);
        BoundedText(result, "phase", 32); BoundedText(result, "image", 512); BoundedText(result, "username", 32); BoundedText(result, "error", 4096);
        Require(result, "desktopReady", JsonValueKind.True);
        DecodeVMCapability(result.GetProperty("launch")); DecodeVMCapability(result.GetProperty("prepare"));
        if (!result.GetProperty("schemaVersion").TryGetInt32(out int schema) || schema != 1 || !VMPhases.Contains(result.GetProperty("phase").GetString()))
            throw new InvalidDataException("VM status is unsupported");
        return result.Deserialize<NativeVMStatus>() ?? throw new InvalidDataException("VM status is missing");
    }

    internal static NativeVMGrant DecodeVMGrant(JsonElement result, string? expectedBrand)
    {
        Exactly(result, "VM grant", ["schemaVersion", "session", "brandId", "intentId", "action", "imageRef", "username", "phase"], []);
        foreach (var (field, limit) in new[] { ("session", 32), ("brandId", 64), ("intentId", 32), ("action", 32), ("imageRef", 512), ("username", 32), ("phase", 32) }) BoundedText(result, field, limit);
        string Text(string field) => result.GetProperty(field).GetString()!;
        if (!result.GetProperty("schemaVersion").TryGetInt32(out int schema) || schema != 1 ||
            !ProtectedPackage.LowerHex(Text("session"), 32) || !ProtectedPackage.LowerHex(Text("intentId"), 32) ||
            expectedBrand is null || Text("brandId") != expectedBrand || !VMActionNames.Contains(Text("action")) || !VMPhases.Contains(Text("phase")))
            throw new InvalidDataException("VM grant is invalid");
        return result.Deserialize<NativeVMGrant>() ?? throw new InvalidDataException("VM grant is missing");
    }

    // One vm:progress event. The stage can come from the builder guest, so it
    // is matched as a bounded word, never shown as a label by itself.
    internal static VMEvent DecodeVMProgress(JsonElement update)
    {
        Exactly(update, "VM progress", ["stage", "percent", "message"], []);
        BoundedText(update, "stage", 64); BoundedText(update, "message", 4096);
        string stage = update.GetProperty("stage").GetString()!;
        if (stage.Length == 0 || stage.Any(c => c is not ((>= 'a' and <= 'z') or '-' or '_')))
            throw new InvalidDataException("VM progress stage is invalid");
        if (update.GetProperty("percent").ValueKind != JsonValueKind.Number || !update.GetProperty("percent").TryGetDouble(out double percent) || !double.IsFinite(percent))
            throw new InvalidDataException("VM progress percent is invalid");
        return update.Deserialize<VMEvent>() ?? throw new InvalidDataException("VM progress is missing");
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
