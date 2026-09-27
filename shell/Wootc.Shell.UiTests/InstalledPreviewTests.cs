using System.Diagnostics;
using System.Text.Json;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using Xunit;

namespace Wootc.Shell.UiTests;

public sealed class InstalledPreviewTests
{
    [Fact]
    public async Task ActualInstalledPreviewBrandAndAuthenticatedStartup()
    {
        string executable = Environment.GetEnvironmentVariable("WOOTC_NATIVE_INSTALLED_EXE")
            ?? throw new InvalidOperationException("Actual installed preview path required");
        string brandSource = Environment.GetEnvironmentVariable("WOOTC_NATIVE_BRAND_SOURCE")
            ?? throw new InvalidOperationException("Selected immutable source brand required");
        using var brand = JsonDocument.Parse(File.ReadAllBytes(brandSource));
        string product = brand.RootElement.GetProperty("productName").GetString()!;
        string distribution = brand.RootElement.GetProperty("name").GetString()!;
        Assert.True(File.Exists(Path.Combine(Path.GetDirectoryName(executable)!, "native-package.json")));
        Assert.True(executable.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase));
        using var automation = new UIA3Automation();
        using var process = Process.Start(new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(executable)! })
            ?? throw new InvalidOperationException("Installed shell did not start");
        _ = process.Handle;
        using var application = Application.Attach(process.Id);
        try
        {
            var window = application.GetMainWindow(automation, TimeSpan.FromSeconds(30));
            Assert.NotNull(window);
            AutomationElement Find(string id) => window.FindFirstDescendant(cf => cf.ByAutomationId(id)) ?? throw new InvalidOperationException($"Installed preview element {id} absent");
            Assert.Equal(product + " — Preview", window.Title);
            Assert.Equal(product, Find("ProductName").Name);
            Assert.Equal(distribution, Find("DistributionName").Name);
            Assert.Contains("cannot install", Find("PreviewStatus").Name);
            Assert.Equal("Offline", Find("ConnectionStatus").Name);
            Find("ConnectEngine").AsButton().Invoke();
            async Task Expect(string id, string expected)
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                while (Find(id).Name != expected)
                {
                    if (deadline.IsCancellationRequested) throw new InvalidOperationException($"Expected installed {id}={expected}; observed {Find(id).Name}; {Find("ConnectionStatus").Name}");
                    await Task.Delay(100, deadline.Token);
                }
            }
            await Expect("ConnectionStatus", "Ready");
            await Expect("StartupRoute", "Review your computer before installation");
            await Expect("StartupObservations", "Running: False; Existing: False; Lifecycle: ; Recovery: ");
            Assert.Null(window.FindFirstDescendant(cf => cf.ByAutomationId("StartInstall")));
            Find("DisconnectEngine").AsButton().Invoke();
            await Expect("ConnectionStatus", "Offline");
            window.Close();
            using var closeDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await process.WaitForExitAsync(closeDeadline.Token);
            Assert.Equal(0, process.ExitCode);
        }
        finally
        {
            if (!process.HasExited) { process.CloseMainWindow(); if (!process.WaitForExit(5000)) { process.Kill(); process.WaitForExit(5000); } }
        }
    }
}
