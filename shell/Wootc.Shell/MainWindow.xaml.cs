using System.Text.Json;
using Microsoft.UI.Xaml;
using Wootc.Shell.Engine;
using Wootc.Shell.Core;
using Wootc.Shell.Native;

namespace Wootc.Shell;

public sealed partial class MainWindow : Window
{
    private readonly StartupController controller;
    private ConsumerConfiguration? configuration;
    private bool updatingConfiguration;
    private long configurationGeneration;
    private CancellationTokenSource? configurationRead;

    public MainWindow()
    {
        InitializeComponent();
        // Local branding is available before any elevation or engine connection.
        string path = Path.Combine(AppContext.BaseDirectory, "Branding", "brand.json");
        var brand = JsonSerializer.Deserialize<Branding>(File.ReadAllText(path))
            ?? throw new InvalidDataException("Preview branding is missing");
        if (string.IsNullOrWhiteSpace(brand.ProductName) || string.IsNullOrWhiteSpace(brand.Name))
            throw new InvalidDataException("Preview branding has no product or distribution identity");
        Title = $"{brand.ProductName} — Preview";
        ProductName.Text = brand.ProductName;
        DistributionName.Text = brand.Name;
        controller = new StartupController(brand, new NativeEngineConnector(AppContext.BaseDirectory, diagnostic =>
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConnectionStatus, diagnostic)));
        Closed += async (_, _) => { InvalidateConfigurationRead(); await controller.DisposeAsync(); };
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
        try
        {
            var snapshot = await controller.ReadConfigurationAsync(read.Token);
            if (generation != configurationGeneration || controller.Connection != ConnectionState.Ready) return;
            var observed = new ConsumerConfiguration(snapshot.BrandId);
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
            if (generation == configurationGeneration) { updatingConfiguration = false; ConfigurationButton.IsEnabled = controller.Connection == ConnectionState.Ready; Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConfigurationButton, $"ConfigurationGeneration:{generation}; State:completed"); }
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
    }

    private void ConfigurationChanged(object sender, object args) => RefreshConfiguration();

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
            _ => throw new InvalidDataException("Unsupported startup route")
        } : "Startup status has not been read";
        var observed = controller.Snapshot;
        StartupObservations.Text = observed is null ? "No authenticated startup observations" :
            $"Running: {observed.Status.Running}; Existing: {observed.Status.Existing}; Lifecycle: {observed.LastRun?.State ?? ""}; Recovery: {observed.Recovery?.Verdict ?? ""}";
    }
}
