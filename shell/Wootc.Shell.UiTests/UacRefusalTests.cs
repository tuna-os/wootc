using System.Diagnostics;
using System.Security;
using System.Text.Json;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.UIA3;
using Microsoft.Win32;
using Xunit;

namespace Wootc.Shell.UiTests;

// Windows itself refuses the elevation: a disposable standard user under
// ConsentPromptBehaviorUser=0 ("automatically deny elevation requests").
// No connector, launcher or result is substituted. The installed shell runs
// as that user and its real runas request reaches the real UAC policy.
public sealed class UacRefusalTests
{
    private const string Declined = "PermissionDeclined: Administrator permission was declined. You can retry.";

    [Fact]
    public async Task ActualUacRefusalKeepsBrandedAssessmentAndOffersRetry()
    {
        string executable = Environment.GetEnvironmentVariable("WOOTC_NATIVE_INSTALLED_EXE")
            ?? throw new InvalidOperationException("Actual installed preview path required");
        string brandSource = Environment.GetEnvironmentVariable("WOOTC_NATIVE_BRAND_SOURCE")
            ?? throw new InvalidOperationException("Selected immutable source brand required");
        string user = Environment.GetEnvironmentVariable("WOOTC_UAC_REFUSAL_USER")
            ?? throw new InvalidOperationException("Disposable standard user required");
        string secret = Environment.GetEnvironmentVariable("WOOTC_UAC_REFUSAL_PASSWORD")
            ?? throw new InvalidOperationException("Disposable standard user credential required");
        using (var policy = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"))
        {
            // Without LUA there is no UAC to refuse; without auto-deny a prompt
            // would wait on the secure desktop. Either makes this test vacuous.
            Assert.Equal(1, Convert.ToInt32(policy?.GetValue("EnableLUA")));
            Assert.Equal(0, Convert.ToInt32(policy?.GetValue("ConsentPromptBehaviorUser")));
        }
        using var brand = JsonDocument.Parse(File.ReadAllBytes(brandSource));
        string product = brand.RootElement.GetProperty("productName").GetString()!;
        Assert.Empty(Process.GetProcessesByName("wootc-engine"));

        using var password = new SecureString();
        foreach (char c in secret) password.AppendChar(c);
        password.MakeReadOnly();
        using var automation = new UIA3Automation();
        using var process = Process.Start(new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            UserName = user,
            Domain = ".",
            Password = password,
            LoadUserProfile = true,
            WorkingDirectory = Path.GetDirectoryName(executable)!
        }) ?? throw new InvalidOperationException("Installed shell did not start as the standard user");
        _ = process.Handle;
        using var application = Application.Attach(process.Id);
        try
        {
            var window = application.GetMainWindow(automation, TimeSpan.FromSeconds(60));
            Assert.NotNull(window);
            AutomationElement Find(string id) => window.FindFirstDescendant(cf => cf.ByAutomationId(id)) ?? throw new InvalidOperationException($"Refusal preview element {id} absent");
            async Task Expect(string id, string expected)
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                while (Find(id).Name != expected)
                {
                    if (deadline.IsCancellationRequested) throw new InvalidOperationException($"Expected {id}={expected}; observed {Find(id).Name}; {Find("ConnectionStatus").Properties.HelpText.ValueOrDefault}");
                    await Task.Delay(100);
                }
            }
            Assert.Equal("Offline", Find("ConnectionStatus").Name);
            for (int attempt = 1; attempt <= 2; attempt++)
            {
                Find("ConnectEngine").AsButton().Invoke();
                await Expect("ConnectionStatus", Declined);
                var retry = Find("ConnectEngine");
                Assert.Equal("Retry administrator permission", retry.Name);
                Assert.True(retry.IsEnabled);
                Assert.False(Find("DisconnectEngine").IsEnabled);
                Assert.Equal(product, Find("ProductName").Name);
                Assert.Equal(product + " — Preview", window.Title);
                Assert.Equal("Startup status has not been read", Find("StartupRoute").Name);
                Assert.Equal("No authenticated startup observations", Find("StartupObservations").Name);
                Assert.Contains("Engine:not-launched", Find("ConnectionStatus").Properties.HelpText.ValueOrDefault);
                Assert.Empty(Process.GetProcessesByName("wootc-engine"));
            }
            window.Close();
            using var closeDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await process.WaitForExitAsync(closeDeadline.Token);
            Assert.Equal(0, process.ExitCode);
        }
        finally
        {
            if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); }
        }
    }
}
