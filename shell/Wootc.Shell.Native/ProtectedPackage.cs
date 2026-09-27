using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Wootc.Shell.Native;

internal sealed class PackageManifest
{
    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; set; }
    [JsonPropertyName("protocolVersion")] public int ProtocolVersion { get; set; }
    [JsonPropertyName("buildId")] public string BuildId { get; set; } = "";
    [JsonPropertyName("brandId")] public string BrandId { get; set; } = "";
    [JsonPropertyName("files")] public Dictionary<string, string> Files { get; set; } = new();
}

internal sealed record ProtectedPackage(string Directory, PackageManifest Manifest)
{
    public string EnginePath => Path.Combine(Directory, "wootc-engine.exe");
    internal static bool LowerHex(string text, int length) => text.Length == length && text.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static bool Trusted(string sid) => sid is "S-1-5-18" or "S-1-5-32-544" or "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464";

    private static void Inspect(string path, bool ancestor)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Reparse points are not allowed in the native package");
        FileSystemSecurity security = (attributes & FileAttributes.Directory) != 0
            ? new DirectoryInfo(path).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access)
            : new FileInfo(path).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
        var raw = new RawSecurityDescriptor(security.GetSecurityDescriptorBinaryForm(), 0);
        if (raw.Owner is null || !Trusted(raw.Owner.Value) || raw.DiscretionaryAcl is null)
            throw new InvalidDataException("The native package has no protected ownership/access boundary");
        uint mutation = 0x500d0040; // GENERIC_ALL/WRITE, WRITE_DAC/OWNER, DELETE, DELETE_CHILD.
        if (!ancestor) mutation |= 0x116; // write/append data, write EA/attributes.
        foreach (GenericAce entry in raw.DiscretionaryAcl)
        {
            if (ancestor && (entry.AceFlags & AceFlags.InheritOnly) != 0) continue;
            if (entry is not CommonAce ace || ace.IsCallback) throw new InvalidDataException("Unsupported native package access rule");
            if (ace.AceQualifier == AceQualifier.AccessDenied) continue;
            if (ace.AceQualifier != AceQualifier.AccessAllowed) throw new InvalidDataException("Unsupported native package access rule");
            if ((entry.AceFlags & AceFlags.InheritOnly) != 0 && ace.SecurityIdentifier.IsWellKnown(WellKnownSidType.CreatorOwnerSid)) continue;
            if (((uint)ace.AccessMask & mutation) != 0 && !Trusted(ace.SecurityIdentifier.Value))
                throw new InvalidDataException("The native package can be changed by an untrusted user");
        }
    }

    private static void InspectParents(string directory)
    {
        string root = Path.GetPathRoot(directory) ?? throw new InvalidDataException("Local native package path required");
        if (root.Length != 3 || root[1] != ':' || new DriveInfo(root).DriveType != DriveType.Fixed)
            throw new InvalidDataException("The native package requires a fixed local drive");
        var parents = new Stack<string>();
        for (var current = new DirectoryInfo(directory); current is not null; current = current.Parent) parents.Push(current.FullName);
        while (parents.Count != 0) { string path = parents.Pop(); Inspect(path, !string.Equals(path, directory, StringComparison.OrdinalIgnoreCase)); }
    }

    public static ProtectedPackage Read(string directory)
    {
        directory = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar);
        InspectParents(directory);
        string manifestPath = Path.Combine(directory, "native-package.json");
        Inspect(manifestPath, false);
        var file = new FileInfo(manifestPath);
        if (file.Length > 1024 * 1024) throw new InvalidDataException("Native manifest exceeds the size limit");
        var manifest = JsonSerializer.Deserialize<PackageManifest>(File.ReadAllBytes(manifestPath), new JsonSerializerOptions { UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow })
            ?? throw new InvalidDataException("The native package manifest is missing");
        var metadata = typeof(ProtectedPackage).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().ToDictionary(a => a.Key, a => a.Value);
        if (manifest.SchemaVersion != 1 || manifest.ProtocolVersion != 1 || !LowerHex(manifest.BuildId, 40) ||
            !metadata.TryGetValue("NativeBuildId", out var build) || build != manifest.BuildId ||
            !metadata.TryGetValue("NativeBrandId", out var brand) || brand != manifest.BrandId)
            throw new InvalidDataException("The native package differs from this shell build");
        if (manifest.Files.Count > 4096) throw new InvalidDataException("Native package artifact count exceeds limit");
        foreach (string required in new[] { "wootc-engine.exe", "Wootc.Shell.exe", "Wootc.Shell.dll", "Wootc.Shell.pri", "Branding/brand.json" })
            if (!manifest.Files.ContainsKey(required)) throw new InvalidDataException("Native package lacks a required artifact");
        var expected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (relative, digest) in manifest.Files)
        {
            if (string.IsNullOrEmpty(relative) || relative == "native-package.json" || relative.Contains('\\') || relative.Contains(':') ||
                relative.StartsWith('/') || relative.Split('/').Any(part => part is "" or "." or "..") || !LowerHex(digest, 64) || !expected.Add(relative))
                throw new InvalidDataException("Invalid or ambiguous native artifact record");
        }
        var observed = new HashSet<string>(StringComparer.Ordinal);
        var pending = new Stack<string>(); pending.Push(directory);
        while (pending.Count != 0)
        {
            string parent = pending.Pop();
            foreach (string path in System.IO.Directory.EnumerateFileSystemEntries(parent))
            {
                Inspect(path, false);
                if ((File.GetAttributes(path) & FileAttributes.Directory) != 0) { pending.Push(path); continue; }
                string relative = Path.GetRelativePath(directory, path).Replace('\\', '/');
                if (relative == "native-package.json") continue;
                if (!manifest.Files.TryGetValue(relative, out string? digest)) throw new InvalidDataException("Unrecorded native package artifact");
                using var stream = File.OpenRead(path);
                if (Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant() != digest) throw new InvalidDataException("Native package artifact digest differs");
                observed.Add(relative);
            }
        }
        if (observed.Count != manifest.Files.Count) throw new InvalidDataException("Native package artifact is missing");
        return new(directory, manifest);
    }
}
