using FlaUI.Core;
using FlaUI.UIA3;
using Xunit;

namespace Wootc.Shell.UiTests;

public sealed class StartupWindowTests
{
    [Fact]
    public void ActualPreviewShowsLocalBrandBeforeEngineConnection()
    {
        string executable = Environment.GetEnvironmentVariable("WOOTC_NATIVE_PREVIEW_EXE")
            ?? throw new InvalidOperationException("The actual published preview executable is required");
        Assert.True(File.Exists(executable), "Published preview executable does not exist");
        using var automation = new UIA3Automation();
        using var application = Application.Launch(executable);
        try
        {
            var window = application.GetMainWindow(automation, TimeSpan.FromSeconds(30));
            Assert.NotNull(window);
            Assert.Equal("wootc — Preview", window.Title);
            Assert.Equal("wootc", window.FindFirstDescendant(cf => cf.ByAutomationId("ProductName")).Name);
            Assert.Equal("TunaOS", window.FindFirstDescendant(cf => cf.ByAutomationId("DistributionName")).Name);
            Assert.Contains("cannot install", window.FindFirstDescendant(cf => cf.ByAutomationId("PreviewStatus")).Name);
        }
        finally { application.Close(); }
    }
}
