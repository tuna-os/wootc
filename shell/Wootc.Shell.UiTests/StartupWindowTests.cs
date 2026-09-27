using System.Diagnostics;
using System.Security.Cryptography;
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
        string resourceIndex = Path.ChangeExtension(executable, ".pri");
        Assert.True(File.Exists(resourceIndex), "Published application resource index does not exist");
        byte[] originalIndexHash = SHA256.HashData(File.ReadAllBytes(resourceIndex));
        await ObserveVisiblePreview(executable);

        // Reproduce the missing-resource failure in the same published bundle.
        // This runs after the visible-window checks and always restores exact bytes.
        string retainedIndex = resourceIndex + ".native-test-retained";
        Assert.False(File.Exists(retainedIndex));
        File.Move(resourceIndex, retainedIndex);
        try
        {
            using var missingResource = Process.Start(new ProcessStartInfo(executable)
            {
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(executable)!,
                RedirectStandardError = true,
                RedirectStandardOutput = true
            }) ?? throw new InvalidOperationException("Missing-resource control did not start");
            var errorOutput = missingResource.StandardError.ReadToEndAsync();
            var standardOutput = missingResource.StandardOutput.ReadToEndAsync();
            try
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                await missingResource.WaitForExitAsync(deadline.Token);
                Assert.NotEqual(0, missingResource.ExitCode);
                Assert.Contains("Cannot locate resource from 'ms-appx:///MainWindow.xaml'", await errorOutput);
                await standardOutput;
            }
            finally
            {
                if (!missingResource.HasExited) { missingResource.Kill(); missingResource.WaitForExit(5000); }
            }
        }
        finally { File.Move(retainedIndex, resourceIndex); }
        Assert.Equal(originalIndexHash, SHA256.HashData(File.ReadAllBytes(resourceIndex)));
        await ObserveVisiblePreview(executable);
    }

    private static async Task ObserveVisiblePreview(string executable)
    {
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

