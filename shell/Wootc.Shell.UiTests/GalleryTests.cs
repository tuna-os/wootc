using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Capturing;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;
using Xunit;

namespace Wootc.Shell.UiTests;

// The native screen gallery: the gallery build of the real shell (its engine
// is recorded fixtures, see Wootc.Shell.Gallery) is driven through every
// screen. Each screen is reached and its actions activated with the keyboard
// only, every control that takes focus has an accessible name, and one
// screen is shown under the Windows high-contrast setting. Screenshots and
// gallery.json go to WOOTC_NATIVE_GALLERY_OUT, an artifact, never git.
public sealed class GalleryTests
{
    private static string Executable => Environment.GetEnvironmentVariable("WOOTC_NATIVE_GALLERY_EXE")
        ?? throw new InvalidOperationException("The published gallery executable is required");
    private static string Output => Environment.GetEnvironmentVariable("WOOTC_NATIVE_GALLERY_OUT")
        ?? throw new InvalidOperationException("The gallery output folder is required");
    private static readonly ControlType[] Interactive = [ControlType.Button, ControlType.CheckBox, ControlType.ComboBox, ControlType.Edit, ControlType.Spinner, ControlType.Slider];

    private sealed record Shot(string Screen, string File, string Scene, string[] ReachedByKeyboard, string Palette);

    private sealed class Session : IDisposable
    {
        private readonly Process process;
        private readonly Application application;
        public readonly UIA3Automation Automation = new();
        public readonly Window Window;
        public readonly string Scene;

        public Session(string scene)
        {
            Scene = scene;
            var start = new ProcessStartInfo(Executable) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(Executable)! };
            start.Environment["WOOTC_NATIVE_GALLERY_SCENE"] = scene;
            process = Process.Start(start) ?? throw new InvalidOperationException("The gallery did not start");
            _ = process.Handle;
            application = Application.Attach(process.Id);
            Window = application.GetMainWindow(Automation, TimeSpan.FromSeconds(30)) ?? throw new InvalidOperationException("The gallery window did not appear");
            Assert.EndsWith("— Screen gallery (recorded fixtures)", Window.Title);
            if (Window.Patterns.Window.IsSupported) Window.Patterns.Window.Pattern.SetWindowVisualState(WindowVisualState.Maximized);
            Window.Focus();
        }

        public AutomationElement? Maybe(string id) => Window.FindFirstDescendant(cf => cf.ByAutomationId(id));
        public AutomationElement Find(string id) => Maybe(id) ?? throw new InvalidOperationException($"Gallery element {id} is absent");

        public async Task<AutomationElement> WaitFor(string id, Func<AutomationElement, bool>? ready = null, int seconds = 30)
        {
            using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
            while (true)
            {
                var element = Maybe(id);
                if (element is not null && (ready is null || ready(element))) return element;
                if (deadline.IsCancellationRequested) throw new InvalidOperationException($"Gallery element {id} did not become ready in scene {Scene}; status={Maybe("ConnectionStatus")?.Name}");
                await Task.Delay(100);
            }
        }

        // Tab until the element has focus. Every focused control on the way
        // must have an accessible name.
        public List<string> Visited = new();
        public async Task TabTo(string id, int limit = 160)
        {
            for (int presses = 0; presses <= limit; presses++)
            {
                var focused = Automation.FocusedElement();
                string focusedId = focused?.Properties.AutomationId.ValueOrDefault ?? "";
                if (focused is not null && Interactive.Contains(focused.Properties.ControlType.ValueOrDefault))
                {
                    Assert.False(string.IsNullOrWhiteSpace(focused.Properties.Name.ValueOrDefault), $"A focusable {focused.Properties.ControlType.ValueOrDefault} ({focusedId}) has no accessible name in scene {Scene}");
                    if (focusedId.Length != 0 && !Visited.Contains(focusedId)) Visited.Add(focusedId);
                }
                if (focusedId == id) return;
                Keyboard.Type(VirtualKeyShort.TAB);
                await Task.Delay(60);
            }
            throw new InvalidOperationException($"Keyboard focus never reached {id} in scene {Scene}; visited {string.Join(",", Visited)}");
        }

        public async Task Press(string id)
        {
            await TabTo(id);
            Assert.True(Find(id).IsEnabled, $"{id} is not enabled in scene {Scene}");
            Keyboard.Type(VirtualKeyShort.SPACE);
            await Task.Delay(200);
        }

        // Every listed control is reachable with Tab from where focus is now.
        public async Task<string[]> Reach(params string[] ids)
        {
            foreach (string id in ids) await TabTo(id);
            return ids;
        }

        public void Dispose()
        {
            try { if (!process.HasExited) { Window.Close(); if (!process.WaitForExit(10000)) process.Kill(); } }
            finally { application.Dispose(); Automation.Dispose(); process.Dispose(); }
        }
    }

    private readonly List<Shot> shots = new();

    private async Task Capture(Session session, string screen, string focusId, string[] reached)
    {
        await session.TabTo(focusId); // focus scrolls the screen into view
        await Task.Delay(600);
        Directory.CreateDirectory(Output);
        string file = screen + ".png";
        FlaUI.Core.Capturing.Capture.Element(session.Window).ToFile(Path.Combine(Output, file));
        string palette = session.Find("ProductName").Properties.HelpText.ValueOrDefault ?? "";
        shots.Add(new(screen, file, session.Scene, reached, palette));
    }

    private async Task Connect(Session session)
    {
        await session.Press("ConnectEngine");
        await session.WaitFor("ConnectionStatus", element => element.Name == "Ready");
    }

    [Fact]
    public async Task EveryNativeScreenIsReachableByKeyboardAndCaptured()
    {
        try
        {
            using (var fresh = new Session("fresh"))
            {
                await Capture(fresh, "startup", "ConnectEngine", await fresh.Reach("ConnectEngine"));
                await Connect(fresh);
                await fresh.Press("ReadVMStatus");
                await fresh.WaitFor("VMTitle", element => element.Name.StartsWith("Linux is shut down", StringComparison.Ordinal));
                await Capture(fresh, "linux-window", "StartLinuxAgain", await fresh.Reach("StartLinuxAgain"));
                await fresh.Press("ReadConfiguration");
                await fresh.WaitFor("ConfigurationObservation", element => element.Name.Contains("storage: observed", StringComparison.Ordinal));
                var reached = await fresh.Reach("ImageChoice", "StorageChoice", "LinuxUsername", "LinuxPassword", "LinuxPasswordConfirmation", "LinuxHostname", "LinuxEncryption", "LinuxWindowsLook");
                await Capture(fresh, "configuration", "ImageChoice", reached);
                var images = fresh.Find("ImageChoice").AsComboBox(); images.Expand(); images.Select(0); images.Collapse();
                var storage = fresh.Find("StorageChoice").AsComboBox(); storage.Expand(); storage.Select(0); storage.Collapse();
                var encryption = fresh.Find("LinuxEncryption").AsComboBox(); encryption.Expand(); encryption.Select(2); encryption.Collapse();
                foreach (var (id, text) in new[] { ("LinuxUsername", "gallery_user"), ("LinuxPassword", "public gallery password"), ("LinuxPasswordConfirmation", "public gallery password"), ("LinuxHostname", "gallery-pc") })
                {
                    await fresh.TabTo(id);
                    Keyboard.Type(text);
                    await Task.Delay(100);
                }
                var size = fresh.Find("LinuxDiskSize");
                if (size.Patterns.RangeValue.IsSupported) size.Patterns.RangeValue.Pattern.SetValue(20);
                await fresh.WaitFor("PrepareInstall", element => element.IsEnabled, 10);
                await fresh.Press("PrepareInstall");
                await fresh.WaitFor("InstallLinux", element => element.IsEnabled);
                await fresh.Press("InstallLinux");
                await fresh.WaitFor("InstallConfirmation");
                await Capture(fresh, "install-confirm", "PrimaryButton", await fresh.Reach("PrimaryButton"));
                Keyboard.Type(VirtualKeyShort.SPACE);
                await fresh.WaitFor("ProgressTitle", element => element.Name.Length != 0);
                await fresh.WaitFor("ProgressStep", element => element.Name != "Starting…" && element.Name.Length != 0);
                await Capture(fresh, "progress", "CancelInstall", Array.Empty<string>());
                await fresh.WaitFor("DoneTitle", element => element.Name.Length != 0, 45);
                await Capture(fresh, "done", "RebootNow", await fresh.Reach("RebootLater", "RebootNow"));
            }
            using (var interrupted = new Session("interrupted"))
            {
                await Connect(interrupted);
                await interrupted.WaitFor("InstallRecovery", element => element.Name.Length != 0);
                await Capture(interrupted, "interrupted", "ReadConfiguration", await interrupted.Reach("DisconnectEngine", "ReadConfiguration"));
            }
            using (var manage = new Session("manage"))
            {
                await Connect(manage);
                await manage.Press("ReadInstallation");
                await manage.WaitFor("ManageCardTitle");
                var reached = await manage.Reach("DeleteLinuxData", "GiveSpaceBack", "RestartIntoLinux", "Reinstall", "UninstallLinux", "CloseWindow");
                await Capture(manage, "manage", "UninstallLinux", reached);
                await manage.Press("UninstallLinux");
                await manage.WaitFor("MaintenanceConfirmation");
                await Capture(manage, "manage-uninstall-confirm", "CloseButton", await manage.Reach("CloseButton"));
                Keyboard.Type(VirtualKeyShort.ESCAPE);
                await manage.WaitFor("ReadInstallation", element => element.IsEnabled);
            }
            using (var recovery = new Session("recovery"))
            {
                await Connect(recovery);
                await recovery.WaitFor("RecoveryTitle");
                await recovery.Press("ReadInstallation");
                await recovery.WaitFor("RecoveryBootState");
                var reached = await recovery.Reach("RemoveLinux", "KeepWindowsOnly", "RepairBoot");
                await Capture(recovery, "recovery", "RemoveLinux", reached);
            }
            using (HighContrast.On())
            {
                await Task.Delay(2000);
                using var contrast = new Session("fresh");
                Assert.Equal("Palette: high-contrast", contrast.Find("ProductName").Properties.HelpText.ValueOrDefault);
                await Capture(contrast, "startup-high-contrast", "ConnectEngine", await contrast.Reach("ConnectEngine"));
            }
        }
        finally
        {
            Directory.CreateDirectory(Output);
            File.WriteAllText(Path.Combine(Output, "gallery.json"), JsonSerializer.Serialize(new { source = "recorded fixtures (shell/Wootc.Shell.Gallery)", shots }, new JsonSerializerOptions { WriteIndented = true }));
        }
        string[] screens = ["startup", "linux-window", "configuration", "install-confirm", "progress", "done", "interrupted", "manage", "manage-uninstall-confirm", "recovery", "startup-high-contrast"];
        Assert.Equal(screens, shots.Select(shot => shot.Screen));
        foreach (var shot in shots) Assert.True(new FileInfo(Path.Combine(Output, shot.File)).Length > 0);
    }

    // Turns the Windows high-contrast setting on for one block and restores
    // the setting the runner had before.
    private sealed class HighContrast : IDisposable
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct HIGHCONTRAST { public int cbSize; public int dwFlags; public IntPtr lpszDefaultScheme; }
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SystemParametersInfoW(int action, int size, ref HIGHCONTRAST value, int update);
        private const int GetHighContrast = 0x0042, SetHighContrast = 0x0043, On_ = 0x1, SendChange = 0x2;
        private readonly int previous;

        private HighContrast(int previous) => this.previous = previous;

        public static HighContrast On()
        {
            var current = new HIGHCONTRAST { cbSize = Marshal.SizeOf<HIGHCONTRAST>() };
            if (!SystemParametersInfoW(GetHighContrast, current.cbSize, ref current, 0)) throw new InvalidOperationException($"High contrast read failed: {Marshal.GetLastWin32Error()}");
            var wanted = new HIGHCONTRAST { cbSize = current.cbSize, dwFlags = current.dwFlags | On_ };
            if (!SystemParametersInfoW(SetHighContrast, wanted.cbSize, ref wanted, SendChange)) throw new InvalidOperationException($"High contrast could not be turned on: {Marshal.GetLastWin32Error()}");
            return new(current.dwFlags);
        }

        public void Dispose()
        {
            var restore = new HIGHCONTRAST { cbSize = Marshal.SizeOf<HIGHCONTRAST>(), dwFlags = previous };
            SystemParametersInfoW(SetHighContrast, restore.cbSize, ref restore, SendChange);
        }
    }
}
