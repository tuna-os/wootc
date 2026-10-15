using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Wootc.Shell.Engine;
using Wootc.Shell.Core;
using Wootc.Shell.Native;

namespace Wootc.Shell;

public sealed partial class MainWindow : Window
{
    private readonly StartupController controller;
    private readonly NativeEngineConnector connector;
    private readonly Branding brand;
    private InstallGate? installGate;
    private string configurationBrandId = "";
    private ConsumerConfiguration? configuration;
    private bool updatingConfiguration;
    private long configurationGeneration;
    private CancellationTokenSource? configurationRead;
    private bool closing;
    private readonly bool observeFixtureInput = Environment.GetEnvironmentVariable("WOOTC_NATIVE_PREVIEW_INPUT_OBSERVATION") == "1";
    private int passwordChanges, confirmationChanges;

    public MainWindow()
    {
        InitializeComponent();
        ConfigurationButton.GotFocus += (_,_) => ConfigurationButton.StartBringIntoView(new BringIntoViewOptions { AnimationDesired=false });
        if (observeFixtureInput)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(LinuxPassword,"InputChangeSequence:0");
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(LinuxPasswordConfirmation,"InputChangeSequence:0");
        }
        // Local branding is available before any elevation or engine connection.
        string path = Path.Combine(AppContext.BaseDirectory, "Branding", "brand.json");
        brand = JsonSerializer.Deserialize<Branding>(File.ReadAllText(path))
            ?? throw new InvalidDataException("Preview branding is missing");
        if (string.IsNullOrWhiteSpace(brand.ProductName) || string.IsNullOrWhiteSpace(brand.Name))
            throw new InvalidDataException("Preview branding has no product or distribution identity");
        Title = $"{brand.ProductName} — Preview";
        ProductName.Text = brand.ProductName;
        DistributionName.Text = brand.Name;
        ApplyBrand(brand, BrandTheme.From(brand));
        connector = new NativeEngineConnector(AppContext.BaseDirectory, diagnostic =>
            DispatcherQueue.TryEnqueue(() => { if (!closing && diagnostic.IsCurrent()) Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConnectionStatus, diagnostic.Projection); }));
        controller = new StartupController(brand, connector);
        InstallButton.Content = $"Advanced: {InstallDisclosure.InstallVerb(brand)} with reboot";
        // Closing the window disconnects both sessions; the engine treats that
        // as a cancellation request for any running install.
        Closed += async (_, _) => { closing=true; InvalidateConfigurationRead(); if (installGate is not null) await installGate.DisposeAsync(); await controller.DisposeAsync(); };
    }
    // Local, validated brand assets render before any elevation request and
    // stay visible after a refusal. High contrast keeps the system palette.
    private void ApplyBrand(Branding brand, BrandTheme theme)
    {
        string palette = "system";
        if (new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast) palette = "high-contrast";
        else if (theme.HasPalette)
        {
            ApplyPalette(theme);
            palette = "brand";
        }
        AutomationProperties.SetHelpText(ProductName, $"Palette: {palette}");
        string logo = Path.Combine(AppContext.BaseDirectory, "Branding", "logo.svg");
        if (File.Exists(logo))
        {
            AutomationProperties.SetName(BrandLogo, $"{brand.Name} logo");
            AutomationProperties.SetHelpText(BrandLogo, "Brand logo loading");
            BrandLogo.Visibility = Visibility.Visible;
            _ = LoadLogoAsync(logo);
        }
        else if (!string.IsNullOrWhiteSpace(brand.LogoEmoji))
        {
            BrandEmoji.Text = brand.LogoEmoji;
            AutomationProperties.SetName(BrandEmoji, brand.LogoEmoji);
            BrandEmoji.Visibility = Visibility.Visible;
        }
    }

    private async Task LoadLogoAsync(string path)
    {
        try
        {
            var source = new SvgImageSource { RasterizePixelHeight = 112 };
            using var stream = File.OpenRead(path);
            var status = await source.SetSourceAsync(stream.AsRandomAccessStream());
            if (status != SvgImageSourceLoadStatus.Success) throw new InvalidDataException($"SVG status {status}");
            BrandLogo.Source = source;
            AutomationProperties.SetHelpText(BrandLogo, "Brand logo loaded");
        }
        catch (Exception error)
        {
            // The product and distribution names remain; never fetch a fallback.
            BrandLogo.Visibility = Visibility.Collapsed;
            AutomationProperties.SetHelpText(BrandLogo, $"Brand logo failed: {error.GetType().Name}");
        }
    }

    private void ApplyPalette(BrandTheme theme)
    {
        static SolidColorBrush Brush(BrandColor color) => new(ColorHelper.FromArgb(255, color.R, color.G, color.B));
        if (theme.Background is { } background)
        {
            BrandRoot.RequestedTheme = theme.Ground == BrandGround.Dark ? ElementTheme.Dark : ElementTheme.Light;
            BrandRoot.Background = Brush(background);
            BrandCard.Background = Brush(theme.Card!.Value);
            var text = Brush(theme.Text!.Value);
            foreach (var block in new[] { ProductName, DistributionName, PreviewHeading, PreviewIntro, PreviewStatus, ConnectionStatus, StartupRouteText, StartupObservations, InstallRecoveryText })
                block.Foreground = text;
        }
        if (theme.Accent is { } accent)
        {
            // Lightweight styling: these keys feed AccentButtonStyle's states.
            var fill = Brush(accent);
            var label = Brush(theme.AccentText!.Value);
            foreach (string key in new[] { "AccentButtonBackground", "AccentButtonBackgroundPointerOver", "AccentButtonBackgroundPressed", "AccentButtonBorderBrush", "AccentButtonBorderBrushPointerOver", "AccentButtonBorderBrushPressed" })
                ConnectButton.Resources[key] = fill;
            foreach (string key in new[] { "AccentButtonForeground", "AccentButtonForegroundPointerOver", "AccentButtonForegroundPressed" })
                ConnectButton.Resources[key] = label;
        }
    }

    private async void Connect_Click(object sender, RoutedEventArgs args)
    {
        ConnectButton.IsEnabled = false;
        ConnectionStatus.Text = "Requesting administrator permission";
        await controller.RequestPermissionAsync();
        UpdateConnection();
    }

    private async void Disconnect_Click(object sender, RoutedEventArgs args)
    {
        DisconnectButton.IsEnabled = false;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(DisconnectButton, $"ConfigurationReadPending:{configurationRead is not null}");
        InvalidateConfigurationRead();
        ConfigurationButton.IsEnabled = false;
        ConnectionStatus.Text = "Disconnecting engine";
        ClearConfiguration();
        try { await controller.DisposeAsync(); }
        catch (Exception error) { ConnectionStatus.Text = $"Disconnect pending: {error.Message}"; }
        UpdateConnection();
    }

    private async void Configuration_Click(object sender, RoutedEventArgs args)
    {
        ConfigurationButton.IsEnabled = false;
        using var read = new CancellationTokenSource();
        configurationRead = read;
        long generation = ++configurationGeneration;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConfigurationButton, $"ConfigurationGeneration:{generation}; State:pending");
        long flushedRequest = 0;
        try
        {
            var snapshot = await controller.ReadConfigurationAsync(read.Token, id =>
            {
                Interlocked.Exchange(ref flushedRequest, id);
                DispatcherQueue.TryEnqueue(() =>
                {
                    if (generation == configurationGeneration && ReferenceEquals(configurationRead, read))
                        Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConfigurationButton, $"ConfigurationGeneration:{generation}; Request:{id}; State:pending");
                });
            });
            if (generation != configurationGeneration || controller.Connection != ConnectionState.Ready) return;
            var observed = new ConsumerConfiguration(snapshot.BrandId);
            configurationBrandId = snapshot.BrandId;
            observed.ApplyCatalogue(ConfigurationProjection.ToCatalogue(snapshot));
            updatingConfiguration = true;
            configuration = observed;
            ImageChoice.ItemsSource = observed.Images;
            StorageChoice.ItemsSource = snapshot.Storage;
            LinuxDiskSize.Value = observed.DiskSizeGb;
            LinuxEncryption.SelectedItem = LinuxEncryption.Items.OfType<Microsoft.UI.Xaml.Controls.ComboBoxItem>().Single(item => (string)item.Tag == observed.Encryption);
            LinuxWindowsLook.IsChecked = observed.WindowsLook;
            ConfigurationObservation.Text = $"Catalogue: {snapshot.CatalogueSource}; channel: {snapshot.Policy.Channel}; storage: {snapshot.StorageStatus}; installation authorization: unavailable";
            ConfigurationPanel.Visibility = Visibility.Visible;
        }
        catch { if (generation == configurationGeneration) { ClearConfiguration(); StartupObservations.Text = "Linux configuration observation is unavailable"; } }
        finally
        {
            if (ReferenceEquals(configurationRead, read)) configurationRead = null;
            if (generation == configurationGeneration) { updatingConfiguration = false; ConfigurationButton.IsEnabled = controller.Connection == ConnectionState.Ready; Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConfigurationButton, $"ConfigurationGeneration:{generation}; Request:{Interlocked.Read(ref flushedRequest)}; State:completed"); }
        }
        if (generation == configurationGeneration) RefreshConfiguration();
    }

    private void InvalidateConfigurationRead()
    {
        ++configurationGeneration;
        configurationRead?.Cancel();
    }

    private void ClearConfiguration()
    {
        configuration = null;
        ConfigurationPanel.Visibility = Visibility.Collapsed;
        ImageChoice.SelectedItem = null; StorageChoice.SelectedItem = null;
        ImageChoice.ItemsSource = null; StorageChoice.ItemsSource = null;
        LinuxUsername.Text = ""; LinuxHostname.Text = "";
        LinuxPassword.Password = ""; LinuxPasswordConfirmation.Password = ""; LinuxLuksPassphrase.Password = "";

        LinuxEncryption.SelectedItem = null; LinuxDiskSize.Value = double.NaN; LinuxWindowsLook.IsChecked = false;
        ImageFacts.Text = ""; StorageFacts.Text = ""; InstallBlockedReason.Text = "";
        _ = DiscardInstallGrantAsync();
    }

    private void ConfigurationChanged(object sender, object args)
    {
        // Optional hosted fixture change-sequence receipt only. No password value
        // is exposed and no configuration/operation capability is granted.
        if (observeFixtureInput && ReferenceEquals(sender,LinuxPassword))
        { passwordChanges=Math.Min(passwordChanges+1,1000000); Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(LinuxPassword,$"InputChangeSequence:{passwordChanges}"); }
        if (observeFixtureInput && ReferenceEquals(sender,LinuxPasswordConfirmation))
        { confirmationChanges=Math.Min(confirmationChanges+1,1000000); Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(LinuxPasswordConfirmation,$"InputChangeSequence:{confirmationChanges}"); }
        RefreshConfiguration();
    }

    private void RefreshConfiguration()
    {
        if (updatingConfiguration || configuration is null) return;
        configuration.SelectImage((ImageChoice.SelectedItem as ConfigurationImage)?.Id ?? "");
        configuration.SelectStorage((StorageChoice.SelectedItem as NativeConfigurationStorage)?.Id ?? "");
        configuration.Username = LinuxUsername.Text;
        configuration.Password = LinuxPassword.Password;

        configuration.PasswordConfirmation = LinuxPasswordConfirmation.Password;
        configuration.Hostname = LinuxHostname.Text;
        configuration.DiskSizeGb = double.IsNaN(LinuxDiskSize.Value) ? 0 : (int)LinuxDiskSize.Value;
        configuration.Encryption = (LinuxEncryption.SelectedItem as Microsoft.UI.Xaml.Controls.ComboBoxItem)?.Tag as string ?? "";
        configuration.LuksPassphrase = LinuxLuksPassphrase.Password;
        configuration.WindowsLook = LinuxWindowsLook.IsChecked == true;
        ImageFacts.Text = configuration.SelectedImage is null ? "Choose an observed image" :
            $"{configuration.SelectedImage.ImageRef}; admission: {configuration.SelectedImage.Admitted}; content verified: {configuration.SelectedImage.ContentVerified}; MOK enrollment required: {configuration.SelectedImage.RequiresMokEnrollment}";
        StorageFacts.Text = configuration.SelectedStorage is null ? "Choose an assessed volume; no drive is selected automatically" :
            $"{configuration.SelectedStorage.DriveLetter}: {configuration.SelectedStorage.FreeBytes} available bytes; partition: {configuration.SelectedStorage.PartitionGuid}; NTFS: {configuration.SelectedStorage.NtfsSerial}";
        InstallBlockedReason.Text = configuration.InstallationBlockedReason;
        // Any change to the plan on screen discards an earlier grant and its
        // install session; the new plan needs its own engine check.
        _ = DiscardInstallGrantAsync();
    }

    private async Task DiscardInstallGrantAsync()
    {
        if (installGate is { State: not InstallGateState.Idle }) await installGate.InvalidateAsync();
        UpdateInstallGate();
    }

    private void UpdateInstallGate()
    {
        var state = installGate?.State ?? InstallGateState.Idle;
        bool busy = state is InstallGateState.Preparing or InstallGateState.Confirming or InstallGateState.Started;
        PrepareInstallButton.IsEnabled = !busy && configuration is { FormProblem.Length: 0 } && controller.Connection == ConnectionState.Ready;
        InstallButton.IsEnabled = installGate?.CanInstall == true;
        InstallGateStatus.Text = state switch
        {
            InstallGateState.Preparing => "Checking this plan with the engine",
            InstallGateState.Granted => "The engine accepted this plan. Nothing changes until you confirm.",
            InstallGateState.Refused or InstallGateState.Failed => installGate!.Reason,
            InstallGateState.Confirming => "Starting the installation",
            InstallGateState.Started => "The installation started. Keep this window open.",
            _ => "",
        };
    }

    private async void PrepareInstall_Click(object sender, RoutedEventArgs args)
    {
        if (configuration is null || configuration.FormProblem.Length != 0 || configurationBrandId.Length == 0) return;
        var draft = configuration.CreateDraft();
        installGate ??= new InstallGate(connector, configurationBrandId);
        var preparing = installGate.PrepareAsync(draft);
        UpdateInstallGate();
        await preparing;
        UpdateInstallGate();
    }

    // The confirmation repeats the legacy launchpad's own disclosures. Cancel
    // is the default button, so Enter never starts an install.
    private async void Install_Click(object sender, RoutedEventArgs args)
    {
        var gate = installGate;
        var grant = gate?.Grant;
        if (gate is null || !gate.CanInstall || grant is null) return;
        var disclosure = InstallDisclosure.For(brand, grant);
        var lines = new StackPanel { Spacing = 8 };
        for (int index = 0; index < disclosure.Lines.Count; index++)
        {
            var line = new TextBlock { Text = disclosure.Lines[index], TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetAutomationId(line, $"InstallDisclosure{index}");
            lines.Children.Add(line);
        }
        var dialog = new ContentDialog
        {
            Title = disclosure.Heading, Content = lines, PrimaryButtonText = disclosure.Action, CloseButtonText = disclosure.Cancel,
            DefaultButton = ContentDialogButton.Close, XamlRoot = Content.XamlRoot,
        };
        AutomationProperties.SetAutomationId(dialog, "InstallConfirmation");
        InstallButton.IsEnabled = false;
        var answer = await dialog.ShowAsync();
        if (answer == ContentDialogResult.Primary)
        {
            var confirming = gate.ConfirmAsync();
            UpdateInstallGate();
            await confirming;
        }
        UpdateInstallGate();
    }

    private void UpdateConnection()
    {
        ConnectionStatus.Text = controller.Problem is null ? controller.Connection.ToString()
            : $"{controller.Connection}: {controller.Problem}";
        ConnectButton.IsEnabled = controller.CanRequestPermission;
        ConfigurationButton.IsEnabled = controller.Connection == ConnectionState.Ready;
        if (controller.Connection != ConnectionState.Ready) ClearConfiguration();
        ConnectButton.Content = controller.Connection == ConnectionState.PermissionDeclined ? "Retry administrator permission" : "Read startup status";
        DisconnectButton.IsEnabled = controller.Connection is ConnectionState.Ready or ConnectionState.DisconnectPending;
        DisconnectButton.Content = controller.Connection == ConnectionState.DisconnectPending ? "Retry disconnect" : "Disconnect engine";
        StartupRouteText.Text = controller.Connection == ConnectionState.Ready ? controller.Route switch
        {
            StartupRoute.Assessment => "Review your computer before installation",
            StartupRoute.Progress => "An installation is running",
            StartupRoute.Manage => "Manage the existing installation",
            StartupRoute.Recovery => "Review the previous installation attempt",
            StartupRoute.Interrupted => "Finish or remove the interrupted installation",
            _ => throw new InvalidDataException("Unsupported startup route")
        } : "Startup status has not been read";
        var observed = controller.Snapshot;
        StartupObservations.Text = observed is null ? "No authenticated startup observations" :
            $"Running: {observed.Status.Running}; Existing: {observed.Status.Existing}; Lifecycle: {observed.LastRun?.State ?? ""}; Recovery: {observed.Recovery?.Verdict ?? ""}; Install: {observed.InstallRecovery?.Class ?? ""}";
        // The engine's own text for the interrupted attempt. No action runs
        // from this preview; the safe actions need the install route.
        var interrupted = controller.Connection == ConnectionState.Ready && controller.Route == StartupRoute.Interrupted ? observed?.InstallRecovery : null;
        InstallRecoveryText.Text = interrupted is null ? "" : $"{interrupted.Title} {interrupted.Message}";
        InstallRecoveryText.Visibility = interrupted is null ? Visibility.Collapsed : Visibility.Visible;
    }
}
