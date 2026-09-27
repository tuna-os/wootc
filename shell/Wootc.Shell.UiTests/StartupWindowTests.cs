using System.Diagnostics;
using FlaUI.Core;
using FlaUI.UIA3;
using Xunit;

namespace Wootc.Shell.UiTests;

public sealed class StartupWindowTests
{
    [Fact]
    public async Task ActualPreviewShowsLocalBrandBeforeEngineConnection()
    {
        string executable = Environment.GetEnvironmentVariable("WOOTC_NATIVE_PREVIEW_EXE")
            ?? throw new InvalidOperationException("The actual published preview executable is required");
        Assert.True(File.Exists(executable), "Published preview executable does not exist");
        using var automation = new UIA3Automation();
        using var process = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            WorkingDirectory = Path.GetDirectoryName(executable)!,
            RedirectStandardError = true,
            RedirectStandardOutput = true
        }) ?? throw new InvalidOperationException("Preview process did not start");
        _ = process.Handle; // Retain our own handle independently of FlaUI retries.
        var stderr = process.StandardError.ReadToEndAsync();
        var stdout = process.StandardOutput.ReadToEndAsync();
        using var application = Application.Attach(process.Id);
        try
        {
            var window = application.GetMainWindow(automation, TimeSpan.FromSeconds(30));
            Assert.NotNull(window);
            Assert.Equal("wootc — Preview", window.Title);
            Assert.Equal("wootc", (window.FindFirstDescendant(cf => cf.ByAutomationId("ProductName")) ?? throw new InvalidOperationException("Product identity is absent")).Name);
            Assert.Equal("TunaOS", (window.FindFirstDescendant(cf => cf.ByAutomationId("DistributionName")) ?? throw new InvalidOperationException("Distribution identity is absent")).Name);
            Assert.Contains("cannot install", (window.FindFirstDescendant(cf => cf.ByAutomationId("PreviewStatus")) ?? throw new InvalidOperationException("Preview status is absent")).Name);
        }
        catch (Exception error)
        {
            if (process.HasExited)
                throw new InvalidOperationException($"Preview exited with code {process.ExitCode}. stderr: {await stderr} stdout: {await stdout}", error);
            throw;
        }
        finally
        {
            // Cleanup must not replace the actual startup/assertion failure.
            if (!process.HasExited)
            {
                process.CloseMainWindow();
                if (!process.WaitForExit(5000)) { process.Kill(); process.WaitForExit(5000); }
            }
        }
    }
}
