using System.Diagnostics;
using System.Security.Cryptography;
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
        Assert.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles) + Path.DirectorySeparatorChar, executable, StringComparison.OrdinalIgnoreCase);
        using var automation = new UIA3Automation();
        var launch = new ProcessStartInfo(executable) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(executable)! };
        launch.Environment["WOOTC_NATIVE_PREVIEW_INPUT_OBSERVATION"]="1";
        using var process = Process.Start(launch)
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
            Assert.Contains("changes nothing until you confirm", Find("PreviewStatus").Name);
            Assert.Equal("Offline", Find("ConnectionStatus").Name);
            // Native brand assets come from the same source brand directory.
            var root = brand.RootElement;
            bool palette = root.TryGetProperty("accent", out _) || root.TryGetProperty("background", out _);
            Assert.Equal(palette ? "Palette: brand" : "Palette: system", Find("ProductName").Properties.HelpText.ValueOrDefault);
            string sourceLogo = Path.Combine(Path.GetDirectoryName(brandSource)!, "logo.svg");
            string installedLogo = Path.Combine(Path.GetDirectoryName(executable)!, "Branding", "logo.svg");
            Assert.Equal(File.Exists(sourceLogo), File.Exists(installedLogo));
            if (File.Exists(sourceLogo))
            {
                Assert.Equal(Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(sourceLogo))), Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(installedLogo))));
                var logo = Find("BrandLogo");
                Assert.Equal(distribution + " logo", logo.Name);
                using var logoDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
                while (logo.Properties.HelpText.ValueOrDefault != "Brand logo loaded")
                {
                    if (logoDeadline.IsCancellationRequested) throw new InvalidOperationException($"Brand logo did not load: {logo.Properties.HelpText.ValueOrDefault}");
                    await Task.Delay(100);
                }
                Assert.True(logo.BoundingRectangle.Height > 0);
                Assert.Null(window.FindFirstDescendant(cf => cf.ByAutomationId("BrandEmoji")));
            }
            else
            {
                Assert.Null(window.FindFirstDescendant(cf => cf.ByAutomationId("BrandLogo")));
                string emoji = root.TryGetProperty("logoEmoji", out var mark) ? mark.GetString() ?? "" : "";
                if (emoji.Length != 0) Assert.Equal(emoji, Find("BrandEmoji").Name);
            }
            Find("ConnectEngine").AsButton().Invoke();
            async Task Expect(string id, string expected)
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(45));
                while (Find(id).Name != expected)
                {
                    if (deadline.IsCancellationRequested) throw new InvalidOperationException($"Expected installed {id}={expected}; observed {Find(id).Name}; {Find("ConnectionStatus").Name}; {Find("ConnectionStatus").Properties.HelpText.Value}; disconnectEnabled={Find("DisconnectEngine").IsEnabled}; disconnectOffscreen={Find("DisconnectEngine").IsOffscreen}");
                    await Task.Delay(100);
                }
            }
            await Expect("ConnectionStatus", "Ready");
            await Expect("StartupRoute", "Review your computer before installation");
            await Expect("StartupObservations", "Running: False; Existing: False; Lifecycle: ; Recovery: ; Install: none");
            Assert.Null(window.FindFirstDescendant(cf => cf.ByAutomationId("StartInstall")));
            Find("ReadConfiguration").AsButton().Invoke();
            using (var configurationDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(60)))
            {
                AutomationElement? configurationObservation=null;
                while (true)
                {
                    configurationObservation=window.FindFirstDescendant(cf=>cf.ByAutomationId("ConfigurationObservation"));
                    if (configurationObservation?.Name.Contains("installation authorization: unavailable") == true) break;
                    if (configurationDeadline.IsCancellationRequested) throw new InvalidOperationException($"Actual configuration RPC/view unavailable; {Find("StartupObservations").Name}; {Find("ConnectionStatus").Properties.HelpText.Value}; disconnectEnabled={Find("DisconnectEngine").IsEnabled}; disconnectOffscreen={Find("DisconnectEngine").IsOffscreen}");
                    await Task.Delay(100);
                }
                Assert.NotNull(configurationObservation);
            }
            using (var firstCompletion = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
            {
                while(!Find("ReadConfiguration").Properties.HelpText.Value.EndsWith("; State:completed",StringComparison.Ordinal))
                {if(firstCompletion.IsCancellationRequested)throw new InvalidOperationException("First configuration view appeared without completed consumer");await Task.Delay(50);}
            }
            string initialGeneration=Find("ReadConfiguration").Properties.HelpText.Value;
            async Task TypePublicPassword(string id)
            {
                const string publicPassword="public component fixture password";
                var field=Find(id);field.Focus();
                Assert.True(field.Properties.HasKeyboardFocus.Value,$"Public {id} typing refused: keyboard focus not observed");
                string previous=field.Properties.HelpText.Value;
                int prior=string.IsNullOrEmpty(previous)?0:int.Parse(previous["InputChangeSequence:".Length..],System.Globalization.CultureInfo.InvariantCulture);
                FlaUI.Core.Input.Keyboard.Type(publicPassword);
                using var inputDeadline=new CancellationTokenSource(TimeSpan.FromSeconds(5));
                while(field.Properties.HelpText.Value!=$"InputChangeSequence:{prior+publicPassword.Length}")
                {if(inputDeadline.IsCancellationRequested)throw new InvalidOperationException($"Public {id} input consumption not observed; {field.Properties.HelpText.Value}; focus={field.Properties.HasKeyboardFocus.Value}; read={Find("ReadConfiguration").Properties.HelpText.Value}");await Task.Delay(50);}
                Assert.True(field.Properties.HasKeyboardFocus.Value,$"Public {id} input receipt arrived without retained keyboard focus");
                Assert.Equal(initialGeneration,Find("ReadConfiguration").Properties.HelpText.Value);
            }
            Assert.False(Find("InstallLinux").IsEnabled);
            Assert.Contains("Choose",Find("InstallBlockedReason").Name);
            var images=Find("ImageChoice").AsComboBox();
            images.Expand();
            Assert.NotEmpty(images.Items);
            images.Select(0);
            images.Collapse();
            Assert.Contains("content verified: False",Find("ImageFacts").Name);
            Find("LinuxUsername").AsTextBox().Text="fixture_user";
            await TypePublicPassword("LinuxPassword");
            await TypePublicPassword("LinuxPasswordConfirmation");
            Assert.False(Find("InstallLinux").IsEnabled);
            var selectedEncryption=Find("LinuxEncryption").AsComboBox().SelectedItem;
            Assert.NotNull(selectedEncryption);
            Assert.Equal("TPM auto-unlock",selectedEncryption.Text);
            // A separate install-purpose engine checks the plan (a second
            // elevation, original-user capture, the plan over the pipe). The
            // default encryption is TPM auto-unlock, which the engine always
            // refuses, so this hosted run can never be granted an intent and
            // never confirms anything.
            var prepareInstall=Find("PrepareInstall").AsButton();
            Assert.False(prepareInstall.IsEnabled);
            var storageChoice=Find("StorageChoice").AsComboBox();
            storageChoice.Expand();int volumes=storageChoice.Items.Length;storageChoice.Collapse();
            Assert.True(volumes>0,"No observed storage volume");
            int imageCount=images.Items.Length;
            for(int image=0;image<imageCount&&!prepareInstall.IsEnabled;image++)
            {
                images.Expand();images.Select(image);images.Collapse();
                for(int volume=0;volume<volumes&&!prepareInstall.IsEnabled;volume++)
                {
                    storageChoice.Expand();storageChoice.Select(volume);storageChoice.Collapse();
                    using var offered=new CancellationTokenSource(TimeSpan.FromSeconds(2));
                    while(!prepareInstall.IsEnabled&&!offered.IsCancellationRequested)await Task.Delay(50);
                }
            }
            if(!prepareInstall.IsEnabled)throw new InvalidOperationException($"No observed image and volume made a complete plan; {Find("InstallBlockedReason").Name}");
            Assert.False(Find("InstallLinux").IsEnabled);
            string stateRoot=Path.Combine(Path.GetPathRoot(Environment.SystemDirectory)!,"wootc");
            bool stateRootBefore=Directory.Exists(stateRoot);
            prepareInstall.Invoke();
            string gateStatus="";
            using(var refusalDeadline=new CancellationTokenSource(TimeSpan.FromSeconds(150)))
            {
                while((gateStatus=Find("InstallGateStatus").Name).Length==0||gateStatus=="Checking this plan with the engine")
                {
                    if(refusalDeadline.IsCancellationRequested)throw new InvalidOperationException($"Install plan check did not finish; {Find("ConnectionStatus").Properties.HelpText.Value}");
                    await Task.Delay(100);
                }
            }
            Assert.True(new[]{"TPM auto-unlock is not available yet","Secure Boot","BitLocker","tested set"}.Any(text=>gateStatus.Contains(text,StringComparison.Ordinal)),
                $"The plan did not reach the engine's own validation: {gateStatus}");
            Assert.DoesNotContain("accepted this plan",gateStatus);
            Assert.False(Find("InstallLinux").IsEnabled);
            Assert.True(Find("PrepareInstall").IsEnabled);
            Assert.Null(window.FindFirstDescendant(cf=>cf.ByAutomationId("InstallConfirmation")));
            Assert.Equal(stateRootBefore,Directory.Exists(stateRoot));
            Console.WriteLine($"Install plan check outcome: {gateStatus}");
            // Drive a real second configuration RPC, then disconnect while its
            // consumer is pending. A late response must not restore the form.
            var secondRead=Find("ReadConfiguration").AsButton();
            string beforeFocus=secondRead.Properties.HelpText.Value;
            secondRead.Focus();
            Assert.Equal(beforeFocus,secondRead.Properties.HelpText.Value);
            using(var visibleDeadline=new CancellationTokenSource(TimeSpan.FromSeconds(5)))
            {
                while(secondRead.IsOffscreen)
                {
                    if(visibleDeadline.IsCancellationRequested)throw new InvalidOperationException($"Focused configuration action remained offscreen; bounds={secondRead.BoundingRectangle}; focus={secondRead.Properties.HasKeyboardFocus.Value}");
                    await Task.Delay(50);
                }
            }
            Assert.True(secondRead.Properties.HasKeyboardFocus.Value);
            Assert.False(secondRead.IsOffscreen);
            using (var completionDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
            {
                while (!secondRead.IsEnabled || !secondRead.Properties.HelpText.Value.EndsWith("; State:completed", StringComparison.Ordinal))
                {
                    if (completionDeadline.IsCancellationRequested) throw new InvalidOperationException($"First configuration consumer did not complete; {secondRead.Properties.HelpText.Value}; enabled={secondRead.IsEnabled}");
                    await Task.Delay(50);
                }
            }
            string completedRead = secondRead.Properties.HelpText.Value;
            string generationPrefix = "ConfigurationGeneration:";
            Assert.StartsWith(generationPrefix, completedRead);
            long completedGeneration = long.Parse(completedRead[generationPrefix.Length..].Split(';')[0], System.Globalization.CultureInfo.InvariantCulture);
            long completedRequest = long.Parse(completedRead.Split(';')[1].Trim()["Request:".Length..], System.Globalization.CultureInfo.InvariantCulture);
            Assert.True(completedRequest > 0);
            bool CurrentRequestPending()
            {
                string observed = secondRead.Properties.HelpText.Value;
                string prefix=$"ConfigurationGeneration:{completedGeneration + 1}; Request:";
                return observed.StartsWith(prefix, StringComparison.Ordinal) && observed.EndsWith("; State:pending", StringComparison.Ordinal) && long.TryParse(observed[prefix.Length..].Split(';')[0], out long request) && request > completedRequest;
            }
            Assert.True(secondRead.IsEnabled);
            try { secondRead.Invoke(); }
            catch (Exception) { throw new InvalidOperationException($"Second read UI dispatch refused; before={completedRead}; after={secondRead.Properties.HelpText.Value}; enabled={secondRead.IsEnabled}"); }
            using (var pendingDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(5)))
            {
                while (secondRead.IsEnabled || !CurrentRequestPending())
                {
                    if (pendingDeadline.IsCancellationRequested) throw new InvalidOperationException("Actual second configuration read did not start");
                    await Task.Delay(50);
                }
            }
            var disconnect=Find("DisconnectEngine").AsButton();
            disconnect.Focus();
            disconnect.Patterns.ScrollItem.PatternOrDefault?.ScrollIntoView();
            using(var disconnectDeadline=new CancellationTokenSource(TimeSpan.FromSeconds(5)))
            {
                while(disconnect.IsOffscreen)
                {
                    if(disconnectDeadline.IsCancellationRequested)throw new InvalidOperationException($"Focused disconnect action remained offscreen; bounds={disconnect.BoundingRectangle}; focus={disconnect.Properties.HasKeyboardFocus.Value}");
                    await Task.Delay(50);
                }
            }
            Assert.True(disconnect.IsEnabled);
            Assert.False(disconnect.IsOffscreen);
            disconnect.Invoke();
            await Expect("ConnectionStatus", "Offline");
            Assert.True(Find("DisconnectEngine").Properties.HelpText.Value == "ConfigurationReadPending:True", "Second configuration read completed before disconnect; overlap was not observed");
            Assert.False(Find("ReadConfiguration").IsEnabled);
            Assert.Null(window.FindFirstDescendant(cf=>cf.ByAutomationId("ConfigurationObservation")));
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
