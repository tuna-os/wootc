using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Wootc.Shell.Core;

namespace Wootc.Shell;

public static class Program
{
    // Replaces the XAML-generated entry point only to refuse an unsupported
    // Windows before any WinUI or engine work. The rest mirrors the generated
    // Main, so startup and resource failures behave exactly as before.
    [STAThread]
    public static int Main(string[] args)
    {
        var observed = Environment.OSVersion.Version;
        if (!MinimumOs.IsSupported(observed))
        {
            string message = MinimumOs.RefusalMessage(observed);
            Console.Error.WriteLine(message);
            _ = MessageBoxW(0, message, "Native installer preview", 0x00000010 /* MB_ICONERROR */);
            return MinimumOs.RefusalExitCode;
        }
        XamlCheckProcessRequirements();
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Microsoft.UI.Xaml.Application.Start(callback =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App();
        });
        return 0;
    }

    [DllImport("Microsoft.ui.xaml.dll")]
    private static extern void XamlCheckProcessRequirements();

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(nint owner, string text, string caption, uint type);
}
