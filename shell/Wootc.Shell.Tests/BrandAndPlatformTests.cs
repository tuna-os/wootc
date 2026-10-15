using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class BrandAndPlatformTests
{
    private static string Repository
    {
        get
        {
            for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
                if (File.Exists(Path.Combine(directory.FullName, "shell", "global.json"))) return directory.FullName;
            throw new InvalidOperationException("Repository root not found");
        }
    }

    public static IEnumerable<object[]> ShippedBrands() =>
        Directory.GetDirectories(Path.Combine(Repository, "app", "branding")).Select(d => new object[] { Path.GetFileName(d) });

    [Theory]
    [MemberData(nameof(ShippedBrands))]
    public void EveryShippedBrandTranslatesToAValidNativeTheme(string id)
    {
        var brand = JsonSerializer.Deserialize<Branding>(File.ReadAllText(Path.Combine(Repository, "app", "branding", id, "brand.json")))!;
        var theme = BrandTheme.From(brand);
        Assert.Equal(!string.IsNullOrEmpty(brand.Accent), theme.Accent is not null);
        Assert.Equal(!string.IsNullOrEmpty(brand.Background), theme.Ground != BrandGround.System);
    }

    [Fact]
    public void DarkBrandGroundsSelectTheDarkControlTheme()
    {
        var bazzite = new Branding { Accent = "#8a2be2", AccentText = "#ffffff", Background = "#0f0f0f", Card = "#1c1c1c", Text = "#f0f0f0" };
        var theme = BrandTheme.From(bazzite);
        Assert.Equal(BrandGround.Dark, theme.Ground);
        Assert.Equal(new BrandColor(0x8a, 0x2b, 0xe2), theme.Accent);
        Assert.Equal(BrandGround.Light, BrandTheme.From(new Branding { Background = "#fafafa", Card = "#ffffff", Text = "#111111" }).Ground);
        Assert.Equal(BrandGround.System, BrandTheme.From(new Branding { Accent = "#2f9e8f", AccentText = "#ffffff" }).Ground);
    }

    [Theory]
    [InlineData("8a2be2")]
    [InlineData("#8a2be")]
    [InlineData("#8a2be2ff")]
    [InlineData("purple")]
    [InlineData("#gg0000")]
    [InlineData("rgb(1,2,3)")]
    public void NonHexColoursAreRefused(string value) =>
        Assert.Throws<InvalidDataException>(() => BrandTheme.From(new Branding { Accent = value, AccentText = "#ffffff" }));

    [Fact]
    public void UnreadableOrPartialPalettesAreRefused()
    {
        Assert.Throws<InvalidDataException>(() => BrandTheme.From(new Branding { Accent = "#ffffff", AccentText = "#fefefe" }));
        Assert.Throws<InvalidDataException>(() => BrandTheme.From(new Branding { Accent = "#3550ec" }));
        Assert.Throws<InvalidDataException>(() => BrandTheme.From(new Branding { Background = "#000000", Text = "#ffffff" }));
        Assert.Throws<InvalidDataException>(() => BrandTheme.From(new Branding { Background = "#000000", Card = "#111111", Text = "#222222" }));
        Assert.Throws<InvalidDataException>(() => BrandTheme.From(new Branding { FontFamily = "ms-appx:///font.ttf#Evil" }));
    }

    [Theory]
    [InlineData(10, 0, 17762, false)]
    [InlineData(10, 0, 14393, false)]
    [InlineData(6, 3, 9600, false)]
    [InlineData(10, 0, 17763, true)]
    [InlineData(10, 0, 26100, true)]
    [InlineData(11, 0, 0, true)]
    public void MinimumOsAdmitsOnlyTheFloorAndLater(int major, int minor, int build, bool supported)
    {
        var observed = new Version(major, minor, build);
        Assert.Equal(supported, MinimumOs.IsSupported(observed));
        if (!supported) Assert.Contains($"build {build}", MinimumOs.RefusalMessage(observed));
    }

    // TargetPlatformMinVersion, SupportedOSPlatformVersion and the setup's
    // MinVersion are separate settings. They must all name the runtime floor.
    [Fact]
    public void ProjectAndSetupFloorsMatchTheRuntimeGate()
    {
        string floor = MinimumOs.Floor.ToString(4);
        foreach (string project in new[] { "Wootc.Shell/Wootc.Shell.csproj", "Wootc.Shell.Native/Wootc.Shell.Native.csproj" })
        {
            var properties = XDocument.Load(Path.Combine(Repository, "shell", project)).Descendants("PropertyGroup").Elements().ToList();
            var supported = properties.Where(e => e.Name.LocalName == "SupportedOSPlatformVersion").Select(e => e.Value).ToList();
            Assert.Equal(new[] { floor }, supported);
            if (project.StartsWith("Wootc.Shell/", StringComparison.Ordinal))
                Assert.Equal(new[] { floor }, properties.Where(e => e.Name.LocalName == "TargetPlatformMinVersion").Select(e => e.Value));
        }
        string setup = File.ReadAllText(Path.Combine(Repository, "shell", "packaging", "preview.iss"));
        Assert.Equal($"10.0.{MinimumOs.Build}", Regex.Match(setup, @"^MinVersion=(\S+)\s*$", RegexOptions.Multiline).Groups[1].Value);
    }
}
