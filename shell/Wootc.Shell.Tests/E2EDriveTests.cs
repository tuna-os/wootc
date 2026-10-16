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
        Assert.Equal(("wootc", "wootc-test", "", "C:", 0), (directive.Username, directive.Hostname, directive.Encryption, directive.StorageId, directive.DiskSizeGb));
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
        var launchpad = new DriveObservation(DriveScreen.Launchpad, true, model.InstallationBlockedReason, "", null, "", model.ObservedStorage);
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
        var observed = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "", model.ObservedStorage);
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

    private static E2EDriveDirective InstallTargeting(string? storageId)
    {
        string raw = Golden("directive-install.json");
        Assert.Contains(",\"storageId\":\"C:\"", raw);
        raw = storageId is null ? raw.Replace(",\"storageId\":\"C:\"", "")
            : raw.Replace("\"storageId\":\"C:\"", "\"storageId\":" + System.Text.Json.JsonSerializer.Serialize(storageId));
        return E2EDriveDirective.Parse(raw);
    }

    // The directive names its target; one observed volume is never the answer.
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("  ")]
    public void AnInstallWithoutATargetIsRefusedEvenWithOneVolume(string? storageId)
    {
        var install = InstallTargeting(storageId);
        var model = Model();
        Assert.Single(model.ObservedStorage!);
        var session = new E2EDriveSession();
        var launchpad = new DriveObservation(DriveScreen.Launchpad, false, model.InstallationBlockedReason, "", null, "", model.ObservedStorage);
        Assert.Equal(DriveCommand.Refuse, session.Next(install, launchpad));
        Assert.Equal(E2EDriveTarget.MissingTarget, session.DriveError);
        // Refused before the screen is even the launchpad, and it stays refused.
        Assert.Equal(DriveCommand.Refuse, new E2EDriveSession().Next(install, launchpad with { Screen = DriveScreen.Loading, Storage = null }));
        Assert.Equal(DriveCommand.Refuse, session.Next(install, launchpad with { SelectedRef = Reference }));
        Assert.False(session.InstallRequested);
        var report = System.Text.Json.JsonDocument.Parse(session.Report(install, launchpad)!).RootElement;
        Assert.Equal(E2EDriveTarget.MissingTarget, report.GetProperty("error").GetString());
        Assert.False(report.GetProperty("imageMismatch").GetBoolean());

        // The configuration refuses the same mapping on its own.
        var outcome = model.ApplyDriveMapping(install.ToInstallMapping(), Run);
        Assert.False(outcome.Mapped);
        Assert.False(outcome.ImageMismatch);
        Assert.Equal(E2EDriveTarget.MissingTarget, outcome.BlockedReason);
        Assert.Null(model.SelectedStorage);
        Assert.Null(model.SelectedImage);
    }

    [Fact]
    public void AnUnknownTargetReportsTheSharedRefusalGolden()
    {
        var install = E2EDriveDirective.Parse(Golden("directive-install.json"));
        var model = Model(Reference, Volume("only-volume", "D"));
        var session = new E2EDriveSession();
        var launchpad = new DriveObservation(DriveScreen.Launchpad, true, model.InstallationBlockedReason, "", null, "", model.ObservedStorage);
        Assert.Equal(DriveCommand.Refuse, session.Next(install, launchpad));
        Assert.Equal("The install drive directive names target volume C:, which matches no observed storage.", session.DriveError);
        Assert.Equal(Golden("report-install-unknown-target.json"), session.Report(install, launchpad));
        Assert.Equal(DriveCommand.Refuse, session.Next(install, launchpad with { InstallButtonDisabled = false }));

        var outcome = model.ApplyDriveMapping(install.ToInstallMapping(), Run);
        Assert.False(outcome.Mapped);
        Assert.Equal(session.DriveError, outcome.BlockedReason);
        Assert.Null(model.SelectedStorage);
    }

    // "C:" is one volume's engine id and another volume's drive letter.
    [Fact]
    public void AnAmbiguousTargetIsRefused()
    {
        var install = E2EDriveDirective.Parse(Golden("directive-install.json"));
        var model = Model(Reference, Volume("C:", "D"), Volume("second", "C"));
        var session = new E2EDriveSession();
        var launchpad = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "", model.ObservedStorage);
        Assert.Equal(DriveCommand.Refuse, session.Next(install, launchpad));
        Assert.Contains("matches more than one observed storage entry", session.DriveError);
        var outcome = model.ApplyDriveMapping(install.ToInstallMapping(), Run);
        Assert.False(outcome.Mapped);
        Assert.Contains("more than one", outcome.BlockedReason);
        Assert.Null(model.SelectedStorage);
    }

    [Theory]
    [InlineData("C:", "C")]
    [InlineData("c:", "C")]
    [InlineData("C", "C")]
    [InlineData("c", "C")]
    [InlineData("volume-two", "D")]
    public void TheTargetMatchesAnEngineIdOrADriveLetter(string storageId, string letter)
    {
        var model = Model(Reference, Volume("volume-one", "C"), Volume("volume-two", "D"));
        var install = InstallTargeting(storageId);
        var session = new E2EDriveSession();
        var launchpad = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "", model.ObservedStorage);
        Assert.Equal(DriveCommand.MapInstall, session.Next(install, launchpad));
        Assert.True(model.ApplyDriveMapping(install.ToInstallMapping(), Run).Mapped);
        Assert.Equal(letter, model.SelectedStorage!.DriveLetter);
        Assert.Null(session.DriveError);
    }

    [Theory]
    [InlineData("VOLUME-ONE")]
    [InlineData("C:\\")]
    [InlineData("CC")]
    [InlineData("E:")]
    public void ANearMissIsNotAMatch(string storageId)
    {
        var model = Model(Reference, Volume("volume-one", "C"), Volume("volume-two", "D"));
        var session = new E2EDriveSession();
        var launchpad = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "", model.ObservedStorage);
        Assert.Equal(DriveCommand.Refuse, session.Next(InstallTargeting(storageId), launchpad));
        Assert.Contains("matches no observed storage", session.DriveError);
    }

    [Fact]
    public void UnreadStorageWaitsInsteadOfGuessing()
    {
        var install = E2EDriveDirective.Parse(Golden("directive-install.json"));
        var session = new E2EDriveSession();
        var launchpad = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "");
        Assert.Equal(DriveCommand.None, session.Next(install, launchpad));
        Assert.Null(session.DriveError);
        Assert.Equal(DriveCommand.Refuse, session.Next(install, launchpad with { Storage = Array.Empty<ConfigurationStorage>() }));
    }

    [Fact]
    public void AMappingRefusalIsReportedNotSwallowed()
    {
        var install = E2EDriveDirective.Parse(Golden("directive-install.json"));
        var session = new E2EDriveSession();
        var launchpad = new DriveObservation(DriveScreen.Launchpad, true, "", "", null, "", Model().ObservedStorage);
        Assert.Equal(DriveCommand.MapInstall, session.Next(install, launchpad));
        session.MarkRefused("The install drive directive names target volume C:, which matches no observed storage.");
        Assert.Equal(DriveCommand.Refuse, session.Next(install, launchpad));
        Assert.Contains("\"error\":\"The install drive directive", session.Report(install, launchpad));
        Assert.Throws<ArgumentException>(() => session.MarkRefused(""));
    }

    [Fact]
    public void AnOversizedTargetIsNotEchoedIntoTheReport()
    {
        string id = new('x', 4000);
        var error = Assert.Throws<E2EDriveRefusal>(() => E2EDriveTarget.Resolve(id, Array.Empty<ConfigurationStorage>()));
        Assert.DoesNotContain(id, error.Message);
        Assert.Contains("(4000 characters)", error.Message);
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
