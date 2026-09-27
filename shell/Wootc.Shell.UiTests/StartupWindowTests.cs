using System.Diagnostics;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
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

    [Fact]
    public async Task ActualAuthenticatedGoStartupRpcSelectsFreshRouteAndDisconnects()
    {
        string published = Environment.GetEnvironmentVariable("WOOTC_NATIVE_PREVIEW_EXE")
            ?? throw new InvalidOperationException("Published preview executable required");
        string buildId = Environment.GetEnvironmentVariable("WOOTC_NATIVE_BUILD_ID")
            ?? throw new InvalidOperationException("Exact native build identity required");
        string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "wootc-native-rpc-test-" + Guid.NewGuid().ToString("N"));
        Assert.False(Directory.Exists(root));
        string stateRoot = Path.Combine(Path.GetPathRoot(root)!, "wootc");
        Assert.False(File.Exists(Path.Combine(stateRoot, "disks", "root.disk")));
        string[] BeforeState() => Directory.Exists(stateRoot) ? Directory.GetFiles(stateRoot, "*", SearchOption.AllDirectories).Order().ToArray() : Array.Empty<string>();
        var before = BeforeState();
        string observations = Path.Combine(Path.GetDirectoryName(published)!, "..", "native-startup-state-observations.json");
        File.WriteAllBytes(observations, JsonSerializer.SerializeToUtf8Bytes(new { buildId, before, phase = "Before authenticated engine launch" }));
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(true, false);
        security.SetOwner(new SecurityIdentifier("S-1-5-32-544"));
        foreach (string sid in new[] { "S-1-5-18", "S-1-5-32-544" })
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(sid), FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier("S-1-5-32-545"), FileSystemRights.ReadAndExecute, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
        new DirectoryInfo(root).Create(security);
        try
        {
            string source = Path.GetDirectoryName(published)!;
            var files = new Dictionary<string, string>();
            foreach (string original in Directory.GetFiles(source, "*", SearchOption.AllDirectories))
            {
                string relative = Path.GetRelativePath(source, original);
                string target = Path.Combine(root, relative);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                File.Copy(original, target);
                files.Add(relative.Replace('\\', '/'), Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(target))).ToLowerInvariant());
            }
            File.WriteAllBytes(Path.Combine(root, "native-package.json"), JsonSerializer.SerializeToUtf8Bytes(new { schemaVersion = 1, protocolVersion = 1, buildId, brandId = "wootc", files }));
            using var automation = new UIA3Automation();
            using var process = Process.Start(new ProcessStartInfo(Path.Combine(root, "Wootc.Shell.exe")) { UseShellExecute = false, WorkingDirectory = root })!;
            _ = process.Handle;
            using var application = Application.Attach(process.Id);
            try
            {
                var window = application.GetMainWindow(automation, TimeSpan.FromSeconds(30));
                Assert.NotNull(window);
                AutomationElement Find(string id) => window.FindFirstDescendant(cf => cf.ByAutomationId(id)) ?? throw new InvalidOperationException($"Preview element {id} is absent");
                Assert.Equal("Offline", Find("ConnectionStatus").Name);
                Find("ConnectEngine").AsButton().Invoke();
                async Task ExpectName(string id, string expected)
                {
                    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                    while (Find(id).Name != expected)
                    {
                        if (deadline.IsCancellationRequested) throw new InvalidOperationException($"Expected {id}={expected}; observed {Find(id).Name}; connection={Find("ConnectionStatus").Name}");
                        await Task.Delay(100, deadline.Token);
                    }
                }
                await ExpectName("ConnectionStatus", "Ready");
                await ExpectName("StartupRoute", "Review your computer before installation");
                await ExpectName("StartupObservations", "Running: False; Existing: False; Lifecycle: ; Recovery: ");
                Assert.Null(window.FindFirstDescendant(cf => cf.ByAutomationId("StartInstall")));
                Find("DisconnectEngine").AsButton().Invoke();
                await ExpectName("ConnectionStatus", "Offline");
                window.Close();
                using var closeDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                await process.WaitForExitAsync(closeDeadline.Token);
                Assert.Equal(0, process.ExitCode);
            }
            finally
            {
                if (!process.HasExited) { process.CloseMainWindow(); if (!process.WaitForExit(5000)) { process.Kill(); process.WaitForExit(5000); } }
            }
            Assert.False(File.Exists(Path.Combine(stateRoot, "disks", "root.disk")));
            string lifecyclePath = Path.Combine(stateRoot, "state.json");
            string recoveryPath = Path.Combine(stateRoot, "install", "recovery-verdict.json");
            Assert.False(File.Exists(lifecyclePath));
            Assert.False(File.Exists(recoveryPath));
            string validFailed = "{\"state\":\"failed\",\"updatedAt\":\"2026-09-27T05:00:00Z\",\"updatedBy\":\"public-native-test\"}";
            foreach (string state in new[] {
                "{\"state\":\"failed\",\"state\":\"healthy\",\"updatedAt\":\"2026-09-27T05:00:00Z\",\"updatedBy\":\"public-native-test\"}",
                "{\"state\":\"healthy\",\"state\":\"failed\",\"updatedAt\":\"2026-09-27T05:00:00Z\",\"updatedBy\":\"public-native-test\"}", validFailed })
            {
                File.WriteAllText(lifecyclePath, state);
                bool malformedRecovery = state == validFailed;
                if (malformedRecovery) { Directory.CreateDirectory(Path.GetDirectoryName(recoveryPath)!); File.WriteAllText(recoveryPath, "{}"); }
                try { await ObserveUnavailableWithoutRoute(Path.Combine(root, "Wootc.Shell.exe")); }
                finally
                {
                    Assert.Equal(state, File.ReadAllText(lifecyclePath));
                    File.Delete(lifecyclePath);
                    if (malformedRecovery) { Assert.Equal("{}", File.ReadAllText(recoveryPath)); File.Delete(recoveryPath); }
                }
            }
            File.WriteAllBytes(observations, JsonSerializer.SerializeToUtf8Bytes(new { buildId, before, after = BeforeState(), scope = "Disposable hosted Windows; actual same-user elevated startup RPC; no interactive UAC or installation" }));
        }
        finally { Directory.Delete(root, recursive: true); }
    }

    private static async Task ObserveUnavailableWithoutRoute(string executable)
    {
        using var automation = new UIA3Automation();
        using var process = Process.Start(new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(executable)! })!;
        _ = process.Handle;
        using var application = Application.Attach(process.Id);
        try
        {
            var window = application.GetMainWindow(automation, TimeSpan.FromSeconds(30));
            Assert.NotNull(window);
            AutomationElement Find(string id) => window.FindFirstDescendant(cf => cf.ByAutomationId(id)) ?? throw new InvalidOperationException($"Preview element {id} is absent");
            Find("ConnectEngine").AsButton().Invoke();
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            while (!Find("ConnectionStatus").Name.StartsWith("Unavailable", StringComparison.Ordinal)) await Task.Delay(100, deadline.Token);
            Assert.Equal("Startup status has not been read", Find("StartupRoute").Name);
            Assert.Equal("No authenticated startup observations", Find("StartupObservations").Name);
            Assert.Null(window.FindFirstDescendant(cf => cf.ByAutomationId("StartInstall")));
            window.Close();
            using var closing = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await process.WaitForExitAsync(closing.Token);
            Assert.Equal(0, process.ExitCode);
        }
        finally
        {
            if (!process.HasExited) { process.CloseMainWindow(); if (!process.WaitForExit(5000)) { process.Kill(); process.WaitForExit(5000); } }
        }
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
