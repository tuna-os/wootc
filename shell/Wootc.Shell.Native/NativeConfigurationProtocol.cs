using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Native;

// Reject absent/defaulted and ambiguous observations before projecting a view.
// Names and types come from the generated engine contract, not a second DTO.
internal static class NativeConfigurationProtocol
{
    internal static NativeConfigurationSnapshot Decode(JsonElement result, string expectedBrand)
    {
        Validate(typeof(NativeConfigurationSnapshot), result);
        var snapshot = result.Deserialize<NativeConfigurationSnapshot>() ?? throw Refused();
        if (string.IsNullOrWhiteSpace(expectedBrand) || snapshot.BrandId != expectedBrand ||
            (snapshot.RootScope == "none" ? snapshot.RootBinding != "" : !System.Text.RegularExpressions.Regex.IsMatch(snapshot.RootBinding, "^[0-9a-f]{64}$")) ||
            snapshot.SchemaVersion != 1 || snapshot.InstallAuthorized || snapshot.OriginalUserCaptured ||
            snapshot.RootScope is not ("none" or "payload" or "installation") ||
            snapshot.PolicySource is not ("environment" or "default" or "trusted-root") ||
            snapshot.StorageStatus is not ("not-observed" or "observed") ||
            snapshot.Bundle.State is not ("absent" or "metadata-only") || snapshot.Bundle.ContentVerified ||
            snapshot.Images.Any(image => image.ContentVerified)) throw Refused();
        if (snapshot.StorageStatus == "not-observed" && snapshot.Storage.Count != 0) throw Refused();
        var consumer = new ConsumerConfiguration(snapshot.BrandId);
        consumer.ApplyCatalogue(ConfigurationProjection.ToCatalogue(snapshot));
        return snapshot;
    }

    private static void Validate(Type type, JsonElement value)
    {
        if (type == typeof(string)) { if (value.ValueKind != JsonValueKind.String) throw Refused(); return; }
        if (type == typeof(bool)) { if (value.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw Refused(); return; }
        if (type == typeof(int)) { if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out _)) throw Refused(); return; }
        if (type == typeof(long)) { if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out _)) throw Refused(); return; }
        if (type.IsGenericType && type.GetGenericTypeDefinition() == typeof(List<>))
        {
            if (value.ValueKind != JsonValueKind.Array || value.GetArrayLength() > 256) throw Refused();
            foreach (var item in value.EnumerateArray()) Validate(type.GetGenericArguments()[0],item);
            return;
        }
        if (value.ValueKind != JsonValueKind.Object) throw Refused();
        var properties = type.GetProperties().ToDictionary(property => property.GetCustomAttribute<JsonPropertyNameAttribute>()?.Name ?? throw Refused(), StringComparer.Ordinal);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var field in value.EnumerateObject())
        {
            if (!seen.Add(field.Name) || !properties.TryGetValue(field.Name,out var property)) throw Refused();
            // The canonical Go branding contract permits a nil catalogue list.
            if (type == typeof(Branding) && field.Name == "catalog" && field.Value.ValueKind == JsonValueKind.Null) continue;
            Validate(property.PropertyType,field.Value);
        }
        foreach (var field in properties.Keys)
            if (!seen.Contains(field) && !(type == typeof(Image) && field == "mokEnroll")) throw Refused();
    }
    private static InvalidDataException Refused() => new("Native configuration observation is incomplete or unsupported");
}
