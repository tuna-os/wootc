using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class InstallDisclosureTests
{
    private static readonly Branding Brand = new() { ProductName = "Fixture Installer", Name = "Fixture OS", InstallVerb = "Switch" };


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
        var profiles = InstallDisclosure.For(Brand, new NativeInstallGrant
        {
            ProfileAccounts = new() { new() { WindowsDir = "田中", LinuxUser = "tanaka" } },
            ProfileWarnings = new() { "Review the generated account for 田中." },
        });
        Assert.Contains("Review the generated account for 田中.", profiles.Lines);
        Assert.Contains("Windows profile 田中 → Linux account tanaka.", profiles.Lines);
    }
}
