using Wootc.Shell.Core;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class E2EDriveTests
{
    private const string Run = "20261015-native-fixture";
    private const string Id = "0123456789abcdef0123456789abcdef";
    private const string Reference = "ghcr.io/tuna-os/yellowfin:gnome";
    private const string MismatchHint = "The requested image does not match an available variant.";

    private static string Golden(string name) =>
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "e2e-drive", name));

    private static ConfigurationStorage Volume(string id, string letter) => new(id, letter,
        "11111111-1111-1111-1111-111111111111", Guid.NewGuid().ToString(), "0123456789abcdef", 256L * 1024 * 1024 * 1024, 200);

    private static ConsumerConfiguration Model(string imageRef = Reference, params ConfigurationStorage[] volumes)
    {
        var model = new ConsumerConfiguration("fixture-brand");
        model.ApplyCatalogue(new ConfigurationCatalogue(1, "fixture-brand", "embedded", new string('a', 64),
            new[] { new ConfigurationImage("yellowfin", "Yellowfin GNOME", imageRef, "green", true, "", false, "", false) },
            "alpha", false, new ConfigurationDefaults(40, "none", "auto", false, false),
            volumes.Length == 0 ? new[] { Volume("only-volume", "C") } : volumes));
        return model;
    }

    [Fact]
    public void ParsesTheHarnessDirectiveBytes()
    {
        var directive = E2EDriveDirective.Parse(Golden("directive-install.json"));
        Assert.Equal((1, Run, Id, "install", Reference), (directive.SchemaVersion, directive.RunId, directive.DirectiveId, directive.Action, directive.Image));
        Assert.Equal(("wootc", "wootc-test", "", "", 0), (directive.Username, directive.Hostname, directive.Encryption, directive.StorageId, directive.DiskSizeGb));
        Assert.DoesNotContain("wootc-e2e-pass", directive.ToString());
        var mapping = directive.ToInstallMapping();
        Assert.Equal("wootc-e2e-pass", mapping.Password);
        Assert.DoesNotContain("wootc-e2e-pass", mapping.ToString());
        Assert.Equal("reboot", E2EDriveDirective.Parse(Golden("directive-reboot.json")).Action);
        Assert.Throws<InvalidOperationException>(() => E2EDriveDirective.Parse(Golden("directive-reboot.json")).ToInstallMapping());
    }

    [Fact]
    public void AcceptsALeadingByteOrderMark()
    {
        Assert.Equal(Id, E2EDriveDirective.Parse("﻿" + Golden("directive-install.json")).DirectiveId);
    }

    [Theory]
    [InlineData("")]
    [InlineData("[]")]
    [InlineData("{\"schemaVersion\":1,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\"}{}")]
    [InlineData("{\"schemaVersion\":1,\"schemaVersion\":1,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\"}")]
    [InlineData("{\"schemaVersion\":1,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\",\"extra\":\"\"}")]
    [InlineData("{\"schemaVersion\":1.0,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\"}")]
    [InlineData("{\"schemaVersion\":\"1\",\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\"}")]
    [InlineData("{\"schemaVersion\":2,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\"}")]
    [InlineData("{\"schemaVersion\":1,\"runId\":\"\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\"}")]
    [InlineData("{\"schemaVersion\":1,\"runId\":\"r\",\"directiveId\":\"0123456789ABCDEF0123456789ABCDEF\",\"action\":\"install\"}")]
    [InlineData("{\"schemaVersion\":1,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"uninstall\"}")]
    [InlineData("{\"schemaVersion\":1,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\"}")]
    [InlineData("{\"schemaVersion\":1,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\",\"image\":7}")]
    public void RefusesMalformedOrAmbiguousDirectives(string raw)
    {
        Assert.ThrowsAny<Exception>(() => E2EDriveDirective.Parse(raw));
    }

    [Fact]
    public void RefusesAnOversizedDirective()
    {
        string raw = "{\"schemaVersion\":1,\"runId\":\"r\",\"directiveId\":\"0123456789abcdef0123456789abcdef\",\"action\":\"install\",\"hostname\":\"" +
            new string('a', E2EDriveDirective.MaximumBytes) + "\"}";
        Assert.Throws<InvalidDataException>(() => E2EDriveDirective.Parse(raw));
    }

    [Fact]
    public void DrivesTheConfigurationAndReportsTheSharedGoldens()
    {
        var install = E2EDriveDirective.Parse(Golden("directive-install.json"));
        var model = Model();
        var session = new E2EDriveSession();
        var launchpad = new DriveObservation(DriveScreen.Launchpad, true, model.InstallationBlockedReason, "", null, "");
        Assert.Equal(DriveCommand.MapInstall, session.Next(install, launchpad));

        var mapped = model.ApplyDriveMapping(install.ToInstallMapping(), Run);
        session.MarkMapped(install);
        Assert.True(mapped.Mapped);
        Assert.Equal(Reference, model.SelectedImage!.ImageRef);
        Assert.Equal("C", model.SelectedStorage!.DriveLetter);
        Assert.Empty(model.FormProblem);

        // This preview cannot authorize installation, so the drive does not click.
        var blocked = launchpad with { Hint = model.InstallationBlockedReason, SelectedRef = model.SelectedImage.ImageRef };
        Assert.Equal(DriveCommand.None, session.Next(install, blocked));
        Assert.Contains("\"installBtnDisabled\":true", session.Report(install, blocked));

        // With an enabled Install control, the same session clicks once.
        var ready = blocked with { InstallButtonDisabled = false, Hint = "" };
        Assert.Equal(DriveCommand.ClickInstall, session.Next(install, ready));
        Assert.Equal(Golden("report-install-ready.json"), session.Report(install, ready));
        session.MarkInstallRequested();
        Assert.Equal(DriveCommand.None, session.Next(install, ready));
        session.MarkInstallDriven();

        var done = new DriveObservation(DriveScreen.Done, null, "", "armed", null, Reference);
        Assert.Equal(Golden("report-install-done.json"), session.Report(install, done));

        var reboot = E2EDriveDirective.Parse(Golden("directive-reboot.json"));
        Assert.Equal(DriveCommand.Reboot, session.Next(reboot, done));
        Assert.Equal(Golden("report-reboot-done.json"), session.Report(reboot, done));
        session.MarkRebootDriven();
        Assert.Equal(DriveCommand.None, session.Next(reboot, done));
    }

    [Fact]
    public void AnUnavailableImageReportsTheSharedMismatchGolden()
    {
        var install = E2EDriveDirective.Parse(Golden("directive-install.json"));
        var model = Model("ghcr.io/example/other:latest");
        var session = new E2EDriveSession();
        var observed = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "");
        Assert.Equal(DriveCommand.MapInstall, session.Next(install, observed));
        var outcome = model.ApplyDriveMapping(install.ToInstallMapping(), Run);
        session.MarkMapped(install);
        Assert.False(outcome.Mapped);
        Assert.True(outcome.ImageMismatch);
        Assert.Equal(MismatchHint, model.FormProblem);
        observed = observed with { Hint = model.FormProblem };
        Assert.Equal(DriveCommand.None, session.Next(install, observed with { InstallButtonDisabled = false }));
        Assert.Equal(Golden("report-install-mismatch.json"), session.Report(install, observed));
    }

    [Fact]
    public void NoStorageIdentityMapsOnlyASingleObservedVolume()
    {
        var mapping = E2EDriveDirective.Parse(Golden("directive-install.json")).ToInstallMapping();
        var two = Model(Reference, Volume("first", "C"), Volume("second", "D"));
        var outcome = two.ApplyDriveMapping(mapping, Run);
        Assert.False(outcome.Mapped);
        Assert.False(outcome.ImageMismatch);
        Assert.Null(two.SelectedStorage);
        Assert.Contains("did not observe exactly one volume", outcome.BlockedReason);
    }

    [Fact]
    public void RefusesAChangedRunOrInstallDirective()
    {
        var install = E2EDriveDirective.Parse(Golden("directive-install.json"));
        var session = new E2EDriveSession();
        var observed = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "");
        session.Next(install, observed);
        string other = Golden("directive-install.json");
        Assert.Throws<InvalidDataException>(() => session.Next(E2EDriveDirective.Parse(other.Replace(Run, "another-run")), observed));
        Assert.Throws<InvalidDataException>(() => session.Next(E2EDriveDirective.Parse(other.Replace(Id, new string('f', 32))), observed));
    }

    [Fact]
    public void RebootNeedsTheDrivenInstallOnTheDoneScreen()
    {
        var reboot = E2EDriveDirective.Parse(Golden("directive-reboot.json"));
        var done = new DriveObservation(DriveScreen.Done, null, "", "armed", null, Reference);
        Assert.Equal(DriveCommand.None, new E2EDriveSession().Next(reboot, done));
    }

    [Fact]
    public void VmPreparationHasNoNativeSurfaceYet()
    {
        var prepare = E2EDriveDirective.Parse(Golden("directive-reboot.json").Replace("\"reboot\"", "\"prepare-vm\""));
        var session = new E2EDriveSession();
        var observed = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "");
        Assert.Equal(DriveCommand.None, session.Next(prepare, observed));
        Assert.Null(session.Report(prepare, observed));
    }
}
