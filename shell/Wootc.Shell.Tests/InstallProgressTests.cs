using System.Text.Json;
using Wootc.Shell.Core;
using Wootc.Shell.Engine;
using Xunit;

namespace Wootc.Shell.Tests;

// The engine's recorded install:progress streams
// (app/native_install_progress_test.go) replayed through the progress view.
public sealed class InstallProgressTests
{
    private static readonly Branding Brand = new() { ProductName = "Fixture Installer", Name = "Fixture OS" };

    internal static IReadOnlyList<ProgressEvent> Replay(string name) =>
        File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "Fixtures", "install-progress", name))
            .Select(line => JsonDocument.Parse(line).RootElement)
            .Select(frame =>
            {
                Assert.Equal("install:progress", frame.GetProperty("method").GetString());
                return frame.GetProperty("params").Deserialize<ProgressEvent>()!;
            }).ToArray();

    // The success stream starts every installer step in catalogue order.
    internal static StepDefinition[] Catalogue() =>
        Replay("success.ndjson").Where(update => !string.IsNullOrEmpty(update.PhaseId))
            .Select(update => new StepDefinition { Id = update.PhaseId!, Owner = "installer", Label = update.PhaseId! })
            .Append(new StepDefinition { Id = "fisherman", Owner = "deployer", Label = "Installing your Linux system..." })
            .ToArray();

    private static InstallProgress Run(string name, Func<ProgressEvent, bool>? stop = null)
    {
        var progress = new InstallProgress(Catalogue());
        foreach (var update in Replay(name))
        {
            progress.Apply(update);
            if (stop?.Invoke(update) == true) break;
        }
        return progress;
    }

    [Fact]
    public void TheCatalogueHasOnlyInstallerSteps()
    {
        var progress = new InstallProgress(Catalogue());
        Assert.Equal(17, progress.Steps.Count);
        Assert.DoesNotContain(progress.Steps, step => step.Id == "fisherman");
        Assert.Equal("Starting…", progress.StepLabel);
        Assert.All(progress.Steps, step => Assert.Equal(InstallStepState.Pending, step.State));
        Assert.Throws<InvalidDataException>(() => new InstallProgress(Array.Empty<StepDefinition>()));
    }

    [Fact]
    public void ASuccessfulRunMarksEarlierStepsDoneAndEndsDone()
    {
        var atBitLocker = Run("success.ndjson", update => update.PhaseId == InstallProgress.BitLockerStep);
        Assert.Equal(InstallProgress.BitLockerStep, atBitLocker.Step);
        Assert.Equal(InstallStepState.Active, atBitLocker.Steps.Single(step => step.Id == InstallProgress.BitLockerStep).State);
        Assert.All(atBitLocker.Steps.TakeWhile(step => step.Id != InstallProgress.BitLockerStep), step => Assert.Equal(InstallStepState.Done, step.State));
        Assert.True(atBitLocker.PastArm);
        var notes = InstallProgressText.Notes(atBitLocker, "D", Brand);
        Assert.Equal(new[]
        {
            "A copy of your recovery key is stored at D:\\wootc\\install, readable only by administrators, so Linux can reach your files on every boot. Uninstalling Fixture Installer erases it.",
            InstallProgressText.Calm(true, Brand),
        }, notes);
        var finished = Run("success.ndjson");
        Assert.True(finished.Done);
        Assert.Null(finished.Error);
        Assert.Equal(100, finished.Percent);
    }

    [Fact]
    public void BeforeTheStartupEntryAFailureSaysNothingOutsideTheFolderChanged()
    {
        var progress = Run("failure-before-arm.ndjson");
        Assert.False(progress.Done);
        Assert.False(progress.PastArm);
        Assert.Equal("public synthetic step failure", progress.Error);
        Assert.Equal(new[]
        {
            "✖ public synthetic step failure",
            "Your files and Windows are unharmed — nothing outside the installation folder was changed. You can safely close this and try again.",
            "Your files and Windows stay untouched. Everything here goes into one folder — until Linux is proven working, nothing permanent changes, and you can undo this at any time.",
        }, InstallProgressText.Notes(progress, "", Brand));
    }

    [Fact]
    public void AfterTheStartupEntryAFailureSaysItWasRemovedAgain()
    {
        var progress = Run("failure-after-arm.ndjson");
        Assert.True(progress.PastArm);
        Assert.Equal(new[]
        {
            "✖ public synthetic step failure",
            "Your files and Windows are unharmed — everything lives in the installation folder, and the one-time startup entry has been removed again. You can safely close this and try again.",
            "Your files and Windows stay untouched. Fixture Installer has added a one-time startup entry for the setup boot — everything else lives in one folder, Windows stays your default, and you can undo this at any time.",
        }, InstallProgressText.Notes(progress, "", Brand));
    }

    [Fact]
    public void PercentIsBoundedAndADoneRunIgnoresLaterEvents()
    {
        var progress = new InstallProgress(Catalogue());
        progress.Apply(new ProgressEvent { Step = "Checking your PC", PhaseId = "Checking your PC", Percent = 250 });
        Assert.Equal(100, progress.Percent);
        progress.Apply(new ProgressEvent { Step = "Checking your PC", Percent = double.NaN });
        Assert.Equal(100, progress.Percent);
        progress.Apply(new ProgressEvent { Step = "done", Percent = 100, Done = true });
        progress.Apply(new ProgressEvent { Step = "error", Error = "late" });
        Assert.True(progress.Done);
        Assert.Null(progress.Error);
    }
}
