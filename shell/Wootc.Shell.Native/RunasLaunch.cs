using System.ComponentModel;
using System.Diagnostics;

namespace Wootc.Shell.Native;

internal sealed record RunasResult(Process? Process, bool Declined);
internal static class RunasLaunch
{
    public static ProcessStartInfo Create(string engine, string session, int sourcePid)
    {
        if (!Path.IsPathFullyQualified(engine) || !ProtectedPackage.LowerHex(session, 32) || sourcePid <= 0)
            throw new InvalidDataException("Invalid retained native launch context");
        var start = new ProcessStartInfo(engine) { UseShellExecute = true, Verb = "runas", WorkingDirectory = Path.GetDirectoryName(engine)! };
        start.ArgumentList.Add("--native-serve"); start.ArgumentList.Add("--session"); start.ArgumentList.Add(session);
        start.ArgumentList.Add("--source-pid"); start.ArgumentList.Add(sourcePid.ToString(System.Globalization.CultureInfo.InvariantCulture));
        return start;
    }
    public static async Task<RunasResult> StartAsync(ProcessStartInfo request, Func<ProcessStartInfo, Process?> launch)
    {
        try { return new(await Task.Run(() => launch(request)), false); }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223) { return new(null, true); }
    }
}
