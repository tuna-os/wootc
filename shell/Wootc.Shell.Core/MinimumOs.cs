namespace Wootc.Shell.Core;

// The single source for the native preview's Windows floor. The project
// settings (TargetPlatformMinVersion, SupportedOSPlatformVersion) and the
// preview setup's MinVersion must name this same build; a Linux test reads
// those files and fails when they drift. This floor comes from the chosen
// Windows App SDK and .NET support contracts. It is not yet proved by running
// the package on build 17763 (docs/winui-shell.md).
public static class MinimumOs
{
    public const int Build = 17763;
    public const string Release = "Windows 10 version 1809";
    public const int RefusalExitCode = 3;
    public static readonly Version Floor = new(10, 0, Build, 0);

    public static bool IsSupported(Version observed) =>
        observed.Major > 10 || (observed.Major == 10 && observed.Minor > 0) ||
        (observed.Major == 10 && observed.Minor == 0 && observed.Build >= Build);

    public static string RefusalMessage(Version observed) =>
        $"This preview requires {Release} (build {Build}) or later. This computer reports Windows {observed.Major}.{observed.Minor} build {observed.Build}. Nothing was changed.";
}
