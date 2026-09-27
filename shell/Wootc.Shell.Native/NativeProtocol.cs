using System.Text.Json;
using System.Text.Json.Serialization;

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
            default: throw new InvalidDataException("Unsupported native startup method");
        }
        return result.Deserialize<T>() ?? throw new InvalidDataException("Engine startup result is missing");
    }
}
