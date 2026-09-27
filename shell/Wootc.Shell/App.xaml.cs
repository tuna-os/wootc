using Microsoft.UI.Xaml;

namespace Wootc.Shell;

public partial class App : Application
{
    private Window? window;
    public App()
    {
        UnhandledException += (_, args) => Console.Error.WriteLine(args.Exception);
        try { InitializeComponent(); }
        catch (Exception error) { Console.Error.WriteLine(error); throw; }
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            window = new MainWindow();
            window.Activate();
        }
        catch (Exception error) { Console.Error.WriteLine(error); throw; }
    }
}
