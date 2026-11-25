using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

// The install progress and done wording. It once had to match the Wails
// screens word for word; those were removed (#346), so these tests now pin the
// native text itself.
public sealed class InstallProgressTextTests
{
    private static readonly Branding Brand = new() { ProductName = "@PRODUCT@", Name = "@DISTRO@" };
    private static readonly ConfigurationImage Image = new("id", "@NAME@", "ref", "green", true, "", true, "@MOK@", false, "@DESKTOP@", "@BASE@");

    [Fact]
    public void MokTextNeedsTheImagesOwnPasswordAndFallsBack()
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
