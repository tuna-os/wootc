using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

// The confirmation uses the legacy launchpad's own words
// (app/frontend/src/screens/launchpad.js), with its HTML emphasis removed.
// InstallDisclosureTests compares every line with that file, so a change to
// either side fails until both say the same thing.
public sealed record InstallDisclosure(string Heading, IReadOnlyList<string> Lines, string Action, string Cancel)
{
    public static string InstallVerb(Branding brand) => string.IsNullOrWhiteSpace(brand.InstallVerb) ? "Install" : brand.InstallVerb;

    public static string DataSafety(Branding brand) =>
        $"Try Linux alongside Windows — no repartitioning, nothing deleted, and fully undoable. Pick a look, set a password, and {brand.ProductName} does the rest.";

    public const string BitLockerRecoveryKey =
        "⚠ Before you continue: Make sure you have your BitLocker recovery key. " +
        "Your PC uses BitLocker to protect drive C:. If the migration encounters trouble, " +
        "you need that key to get back into Windows. You can find it at " +
        "Control Panel → BitLocker Drive Encryption → Back up recovery key, " +
        "or in your Microsoft account under Devices.";

    public static string FastStartup(Branding brand) =>
        "Windows Fast Startup keeps the disk half-asleep between boots, which would " +
        $"corrupt files shared with Linux. {brand.ProductName} turns it off during setup — startup may look " +
        "slightly different afterwards, and everything else is unaffected.";

    public const string SecureBootChainPrefix = "⚠ One check we could not make: ";

    // The engine's grant decides which disclosures apply; the shell does not
    // re-derive BitLocker, Fast Startup or Secure Boot facts on its own.
    public static InstallDisclosure For(Branding brand, NativeInstallGrant grant)
    {
        var lines = new List<string> { DataSafety(brand) };
        if (grant.SecureBootChainWarning.Length != 0) lines.Add(SecureBootChainPrefix + grant.SecureBootChainWarning);
        if (grant.BitLockerOn && grant.BitLockerRecoveryKeyWarning) lines.Add(BitLockerRecoveryKey);
        if (grant.FastStartupOn) lines.Add(FastStartup(brand));
        return new($"{InstallVerb(brand)} {brand.Name}", lines, $"Advanced: {InstallVerb(brand)} with reboot", "Cancel");
    }
}
