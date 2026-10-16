using System.Text.RegularExpressions;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

// Word for word with the legacy launchpad. The JavaScript string pieces are
// joined, its <b> emphasis removed and its brand helpers named, then each
// native line must appear unchanged.
public sealed class InstallDisclosureTests
{
    private static readonly Branding Brand = new() { ProductName = "Fixture Installer", Name = "Fixture OS", InstallVerb = "Switch" };

    private static string Launchpad()
    {
        string source = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "launchpad.js"));
        source = Regex.Replace(source, @"['`]\s*\+\s*['`]", "");
        return source.Replace("<b>", "").Replace("</b>", "");
    }

    private static string AsLegacy(string native) => native
        .Replace(Brand.ProductName, "${productName()}")
        .Replace($"{Brand.InstallVerb} {Brand.Name}", "${installVerb()} ${distroName()}")
        .Replace($"Advanced: {Brand.InstallVerb} with reboot", "Advanced: ${installVerb()} with reboot");

    public static TheoryData<string> Lines() => new()
    {
        InstallDisclosure.DataSafety(Brand),
        InstallDisclosure.BitLockerRecoveryKey,
        InstallDisclosure.FastStartup(Brand),
        InstallDisclosure.SecureBootChainPrefix.TrimEnd(),
        $"Advanced: {InstallDisclosure.InstallVerb(Brand)} with reboot",
        $"{InstallDisclosure.InstallVerb(Brand)} {Brand.Name}",
    };

    [Theory]
    [MemberData(nameof(Lines))]
    public void NativeLinesMatchTheLegacyLaunchpad(string line) =>
        Assert.Contains(AsLegacy(line), Launchpad());

    [Fact]
    public void TheGrantDecidesWhichDisclosuresApply()
    {
        var plain = InstallDisclosure.For(Brand, new NativeInstallGrant());
        Assert.Equal("Switch Fixture OS", plain.Heading);
        Assert.Equal(new[] { InstallDisclosure.DataSafety(Brand) }, plain.Lines);
        Assert.Equal("Advanced: Switch with reboot", plain.Action);
        Assert.Equal("Cancel", plain.Cancel);
        var full = InstallDisclosure.For(Brand, new NativeInstallGrant { BitLockerOn = true, BitLockerRecoveryKeyWarning = true, FastStartupOn = true, SecureBootChainWarning = "The firmware certificate list could not be read." });
        Assert.Equal(new[]
        {
            InstallDisclosure.DataSafety(Brand),
            "⚠ One check we could not make: The firmware certificate list could not be read.",
            InstallDisclosure.BitLockerRecoveryKey,
            InstallDisclosure.FastStartup(Brand),
        }, full.Lines);
        var keyWithoutBitLocker = InstallDisclosure.For(Brand, new NativeInstallGrant { BitLockerRecoveryKeyWarning = true });
        Assert.DoesNotContain(InstallDisclosure.BitLockerRecoveryKey, keyWithoutBitLocker.Lines);
        Assert.Equal("Install", InstallDisclosure.InstallVerb(new Branding { ProductName = "P", Name = "N" }));
    }
}
