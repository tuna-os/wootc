using Microsoft.UI.Xaml;

namespace Wootc.Shell;

public partial class App : Application
{
    private Window? window;
    public App()
    {
        UnhandledException += (_, args) => ReportStartupFailure(args.Exception);
        if (Environment.GetEnvironmentVariable("WOOTC_NATIVE_PREVIEW_DIAGNOSTICS") == "1")
        {
            DebugSettings.IsXamlResourceReferenceTracingEnabled = true;
            DebugSettings.XamlResourceReferenceFailed += (_, args) => Console.Error.WriteLine(args.Message);
        }
        try { InitializeComponent(); }
        catch (Exception error) { ReportStartupFailure(error); throw; }
    }
    private static void ReportStartupFailure(Exception error)
    {
        Console.Error.WriteLine($"Native startup HRESULT: 0x{error.HResult:X8}");
        // CsWinRT preserves these error details separately from ToString().
        // Keep the diagnostic whitelist confined to the native startup error.
        foreach (string key in new[] { "Description", "RestrictedDescription" })
            if (error.Data[key] is string detail) Console.Error.WriteLine($"{key}: {detail}");
        Console.Error.WriteLine(error);
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            window = new MainWindow();
            window.Activate();
        }
        catch (Exception error) { ReportStartupFailure(error); throw; }
    }
}
