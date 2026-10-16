using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using Wootc.Shell.Native;
using Xunit;

namespace Wootc.Shell.NativeTests;

public sealed class PackageTests
{
    [Fact]
    public void ActualProtectedPackageRequiresMatchingManagedBytesAndAccessRules()
    {
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "wootc-native-dotnet-test-" + Guid.NewGuid().ToString("N"));
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
        foreach (string sid in new[] { "S-1-5-18", "S-1-5-32-544" })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.ReadAndExecute, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        Assert.False(Directory.Exists(root));
        new DirectoryInfo(root).Create(security);
        try
        {
            var metadata = typeof(NativeEngineConnector).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().ToDictionary(a => a.Key, a => a.Value);
            var manifest = new PackageManifest { SchemaVersion = 1, ProtocolVersion = 1, BuildId = metadata["NativeBuildId"]!, BrandId = metadata["NativeBrandId"]! };
            Assert.True(ProtectedPackage.LowerHex(manifest.BuildId, 40));
            foreach (string relative in new[] { "wootc-engine.exe", "Wootc.Shell.exe", "Wootc.Shell.dll", "Wootc.Shell.pri", "Branding/brand.json" })
            {
                string path = Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, "Public synthetic package " + relative);
                manifest.Files.Add(relative, Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(path))).ToLowerInvariant());
            }
            void WriteManifest() => File.WriteAllBytes(Path.Combine(root, "native-package.json"), JsonSerializer.SerializeToUtf8Bytes(manifest));
            WriteManifest();
            Assert.Equal(manifest.BuildId, ProtectedPackage.Read(root).Manifest.BuildId);
            string assembly = Path.Combine(root, "Wootc.Shell.dll");
            byte[] original = File.ReadAllBytes(assembly);
            File.WriteAllText(assembly, "Other managed build");
            Assert.Throws<InvalidDataException>(() => ProtectedPackage.Read(root));
            File.WriteAllBytes(assembly, original);
            string foreign = Path.Combine(root, "foreign.dll");
            File.WriteAllText(foreign, "Unrecorded dependency");
            Assert.Throws<InvalidDataException>(() => ProtectedPackage.Read(root));
            File.Delete(foreign);
            manifest.Files.Add("../outside", new string('a', 64)); WriteManifest();
            Assert.Throws<InvalidDataException>(() => ProtectedPackage.Read(root));
            manifest.Files.Remove("../outside"); WriteManifest();
            Assert.Equal(manifest.BuildId, ProtectedPackage.Read(root).Manifest.BuildId);
            var writable = new FileInfo(assembly).GetAccessControl();
            writable.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.Write, AccessControlType.Allow));
            new FileInfo(assembly).SetAccessControl(writable);
            Assert.Throws<InvalidDataException>(() => ProtectedPackage.Read(root));
            Assert.Equal(original, File.ReadAllBytes(assembly)); // Refusal does not repair/delete the artifact.
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}
