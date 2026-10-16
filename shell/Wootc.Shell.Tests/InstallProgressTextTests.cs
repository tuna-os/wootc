using System.Text.RegularExpressions;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

// Word for word with the legacy progress and done screens. String pieces are
// joined, HTML removed, whitespace collapsed and JavaScript escapes undone;
// each native line, with its values named as the legacy template names them,
// must then appear unchanged.
public sealed class InstallProgressTextTests
{
    private static readonly Branding Brand = new() { ProductName = "@PRODUCT@", Name = "@DISTRO@" };
    private static readonly ConfigurationImage Image = new("id", "@NAME@", "ref", "green", true, "", true, "@MOK@", false, "@DESKTOP@", "@BASE@");

    private static string Legacy(string file)
    {
        string source = File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", file));
        source = Regex.Replace(source, @"['`]\s*\+\s*['`]", "");
        source = Regex.Replace(source, "<[^>]+>", "");
        source = Regex.Replace(source, @"\s+", " ");
        return source.Replace("\\\\", "\\");
    }

    private static void Same(string file, string native, params (string Value, string Template)[] names)
    {
        foreach (var (value, template) in names) native = native.Replace(value, template);
        native = native.Replace("@DISTRO@", "${distroName()}").Replace("@PRODUCT@", "${productName()}");
        Assert.Contains(native, Legacy(file));
    }

    [Fact]
    public void ProgressLinesMatchTheLegacyScreen()
    {
        Same("progress.js", InstallProgressText.Title(Brand));
        Same("progress.js", InstallProgressText.Subtitle(Image), ("@NAME@", "${state.selected?.name || ''}"), ("@DESKTOP@", "${state.selected?.desktopName || ''}"), ("@BASE@", "${state.selected?.base || ''}"));
        Same("progress.js", InstallProgressText.BitLockerKeyCopy("@DRIVE@", Brand), ("@DRIVE@", "${state.progress.storageDrive || 'C'}"));
        Same("progress.js", InstallProgressText.ErrorCalm(true));
        Same("progress.js", InstallProgressText.ErrorCalm(false));
        Same("progress.js", InstallProgressText.Calm(true, Brand));
        Same("progress.js", InstallProgressText.Calm(false, Brand));
        Assert.Contains("'✖ ' + state.progress.error", Legacy("progress.js"));
        Assert.Equal("✖ x", InstallProgressText.ErrorLine("x"));
        Assert.Contains("'Starting…'", Legacy("progress.js"));
        Assert.Contains($"btn('{InstallProgressText.Cancel}', 'btn btn-ghost btn-danger'", Legacy("progress.js"));
    }

    [Fact]
    public void DoneLinesMatchTheLegacyScreen()
    {
        Same("done.js", InstallProgressText.DoneTitle(Brand));
        Same("done.js", InstallProgressText.DoneBody(Image, Brand), ("@NAME@", "${state.selected?.name || distroName()}"), ("@DESKTOP@", "${state.selected?.desktopName || ''}"));
        Same("done.js", InstallProgressText.DoneSafety);
        Same("done.js", InstallProgressText.MokEnrollment(Image)!, ("Driver trust for @NAME@", "Driver trust for ${state.selected?.name || 'this system'}"), ("trust @NAME@ drivers", "trust ${state.selected?.name || 'the'} drivers"), ("@MOK@", "${state.selected.mokEnroll}"));
        Same("done.js", InstallProgressText.SaveWork);
        Assert.Contains($"btn('{InstallProgressText.RebootLater}'", Legacy("done.js"));
        Assert.Contains($"btn('{InstallProgressText.RebootNow}'", Legacy("done.js"));
    }

    [Fact]
    public void MokTextNeedsTheImagesOwnPasswordAndFallsBackLikeTheLegacyScreen()
    {
        Assert.Null(InstallProgressText.MokEnrollment(Image with { MokEnrollment = "" }));
        Assert.Null(InstallProgressText.MokEnrollment(null));
        string unnamed = InstallProgressText.MokEnrollment(Image with { Name = "" })!;
        Assert.StartsWith("Driver trust for this system:", unnamed);
        Assert.Contains("permission to trust the drivers", unnamed);
        Assert.Contains("type the password @MOK@.", unnamed);
        Assert.StartsWith("Preparation for @DISTRO@ ", InstallProgressText.DoneBody(Image with { Name = "" }, Brand));
    }
}
