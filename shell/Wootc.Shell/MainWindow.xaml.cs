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
        ApplyBrand(brand, BrandTheme.From(brand));
        controller = new StartupController(brand, new NativeEngineConnector(AppContext.BaseDirectory, diagnostic =>
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(ConnectionStatus, diagnostic)));
        Closed += async (_, _) => { await controller.DisposeAsync(); };
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
            foreach (var block in new[] { ProductName, DistributionName, PreviewHeading, PreviewIntro, PreviewStatus, ConnectionStatus, StartupRouteText, StartupObservations })
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
