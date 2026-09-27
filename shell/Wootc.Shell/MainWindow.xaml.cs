using System.Text.Json;
using Microsoft.UI.Xaml;
using Wootc.Shell.Engine;
using Wootc.Shell.Core;
using Wootc.Shell.Native;

namespace Wootc.Shell;

public sealed partial class MainWindow : Window
{
    private readonly StartupController controller;

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
        controller = new StartupController(brand, new NativeEngineConnector(AppContext.BaseDirectory));
        Closed += async (_, _) => { await controller.DisposeAsync(); };
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
        try { await controller.DisposeAsync(); }
        catch (Exception error) { ConnectionStatus.Text = $"Disconnect pending: {error.Message}"; }
        UpdateConnection();
    }

    private void UpdateConnection()
    {
        ConnectionStatus.Text = controller.Problem is null ? controller.Connection.ToString()
            : $"{controller.Connection}: {controller.Problem}";
        ConnectButton.IsEnabled = controller.CanRequestPermission;
        ConnectButton.Content = controller.Connection == ConnectionState.PermissionDeclined ? "Retry administrator permission" : "Read startup status";
        DisconnectButton.IsEnabled = controller.Connection is ConnectionState.Ready or ConnectionState.DisconnectPending;
        StartupRouteText.Text = controller.Connection == ConnectionState.Ready ? controller.Route switch
        {
            StartupRoute.Assessment => "Review your computer before installation",
            StartupRoute.Progress => "An installation is running",
            StartupRoute.Manage => "Manage the existing installation",
            StartupRoute.Recovery => "Review the previous installation attempt",
            _ => throw new InvalidDataException("Unsupported startup route")
        } : "";
        var observed = controller.Snapshot;
        StartupObservations.Text = observed is null ? "" :
            $"Running: {observed.Status.Running}; Existing: {observed.Status.Existing}; Lifecycle: {observed.LastRun?.State ?? ""}; Recovery: {observed.Recovery?.Verdict ?? ""}";
    }
}
