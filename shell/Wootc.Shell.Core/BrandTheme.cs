using System.Globalization;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

public readonly record struct BrandColor(byte R, byte G, byte B)
{
    // Only the #rrggbb form that app/branding/*/brand.json uses. CSS keywords,
    // alpha and functions are not a native colour contract.
    public static BrandColor Parse(string value)
    {
        if (value.Length != 7 || value[0] != '#' || !value.Skip(1).All(Uri.IsHexDigit))
            throw new InvalidDataException("Brand colours must be #rrggbb");
        return new(Hex(value, 1), Hex(value, 3), Hex(value, 5));
    }
    private static byte Hex(string value, int offset) => byte.Parse(value.AsSpan(offset, 2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture);

    // WCAG 2.x relative luminance and contrast ratio.
    public double Luminance
    {
        get
        {
            static double Channel(byte c) { double s = c / 255.0; return s <= 0.04045 ? s / 12.92 : Math.Pow((s + 0.055) / 1.055, 2.4); }
            return 0.2126 * Channel(R) + 0.7152 * Channel(G) + 0.0722 * Channel(B);
        }
    }
    public static double Contrast(BrandColor a, BrandColor b)
    {
        double light = Math.Max(a.Luminance, b.Luminance), dark = Math.Min(a.Luminance, b.Luminance);
        return (light + 0.05) / (dark + 0.05);
    }
}

public enum BrandGround { System, Light, Dark }

// Native translation of the brand palette. Only identity fields that have a
// native meaning are carried: palette and typeface name. theme.css (radii,
// gradients, pill buttons) is not translated; CSS is not a native theme
// contract (docs/winui-shell.md, "Native distro identity").
public sealed record BrandTheme(BrandColor? Accent, BrandColor? AccentText, BrandColor? Background, BrandColor? Card, BrandColor? Text, string? FontFamily)
{
    // Body text needs WCAG AA; an accent button label is large/bold UI text.
    public const double BodyContrast = 4.5;
    public const double AccentContrast = 3.0;

    public BrandGround Ground => Background is null ? BrandGround.System
        : Background.Value.Luminance < 0.18 ? BrandGround.Dark : BrandGround.Light;

    public bool HasPalette => Accent is not null || Background is not null;

    public static BrandTheme From(Branding brand)
    {
        BrandColor? Optional(string value) => string.IsNullOrEmpty(value) ? null : BrandColor.Parse(value);
        var theme = new BrandTheme(Optional(brand.Accent), Optional(brand.AccentText), Optional(brand.Background), Optional(brand.Card), Optional(brand.Text),
            string.IsNullOrWhiteSpace(brand.FontFamily) ? null : brand.FontFamily.Trim());
        if ((theme.Accent is null) != (theme.AccentText is null))
            throw new InvalidDataException("A brand accent needs its text colour, and the reverse");
        if (theme.Accent is { } accent && BrandColor.Contrast(accent, theme.AccentText!.Value) < AccentContrast)
            throw new InvalidDataException("Brand accent text is unreadable on the accent");
        bool anyGround = theme.Background is not null || theme.Card is not null || theme.Text is not null;
        if (anyGround && (theme.Background is null || theme.Card is null || theme.Text is null))
            throw new InvalidDataException("A brand ground needs background, card and text together");
        if (theme.Background is { } background)
        {
            if (BrandColor.Contrast(background, theme.Text!.Value) < BodyContrast || BrandColor.Contrast(theme.Card!.Value, theme.Text.Value) < BodyContrast)
                throw new InvalidDataException("Brand text is unreadable on its ground");
        }
        if (theme.FontFamily is { } font && (font.Length > 64 || font.Any(c => char.IsControl(c) || c is '#' or '/' or '\\' or ',' or ':')))
            throw new InvalidDataException("Brand font family is not a plain family name");
        return theme;
    }
}
