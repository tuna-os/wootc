using System.Text.Json;
using Microsoft.UI.Xaml;
using Wootc.Shell.Engine;

namespace Wootc.Shell;

public sealed partial class MainWindow : Window
{
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
    }
}
