using Wootc.Shell.Core;
using Xunit;

namespace Wootc.Shell.Tests;

public sealed class ConsumerConfigurationTests
{
    private const string StorageId = "observed-volume-identity";
    private const string Reference = "ghcr.io/tuna-os/yellowfin:gnome";
    private static ConfigurationCatalogue Catalogue() => new(1, "wootc", "embedded", new string('a', 64),
        new[] { new ConfigurationImage("yellowfin", "Yellowfin GNOME", Reference, "green", true, "", false, "", false) }, "alpha", false,
        new ConfigurationDefaults(40, "tpm2-luks", "auto", false, false), new[] { new ConfigurationStorage(StorageId, "F",
            "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222", "0123456789abcdef", 128L * 1024 * 1024 * 1024, 100) });
    private static ConsumerConfiguration Complete()
    {
        var model = new ConsumerConfiguration("wootc");
        model.ApplyCatalogue(Catalogue());
        Assert.True(model.SelectImage("yellowfin"));
        Assert.True(model.SelectStorage(StorageId));
        model.Username = "linux_user";
        model.Password = "public fixture password";
        model.PasswordConfirmation = "public fixture password";
        model.Hostname = "linux-pc";
        return model;
    }
    private static InstallDriveMapping Directive(string imageRef = Reference, string run = "hosted-current", string id = "1234567890abcdef1234567890abcdef") =>
        new() { SchemaVersion = 1, RunId = run, DirectiveId = id, Action = "install", ImageRef = imageRef,
            Username = "fixture", Password = "public fixture password", Hostname = "fixture-pc", DiskSizeGb = 48, Encryption = "", StorageId = StorageId };

    [Fact]
    public void DraftDoesNotGrantInstallationAuthorization()
    {
        var model = Complete();
        Assert.Empty(model.FormProblem);
        Assert.False(model.CanInstall);
        Assert.Equal("This native preview cannot authorize installation or change storage.", model.InstallationBlockedReason);
        var draft = model.CreateDraft();
        Assert.Equal(Reference, draft.ImageRef);
        Assert.Equal("linux_user", draft.Username);
        Assert.Equal("linux-pc", draft.Hostname);
        Assert.Equal("auto", draft.Bootloader);
        Assert.False(draft.ComposeFs);
        Assert.Equal("F", draft.StorageDrive);
        Assert.Equal("tpm2-luks", draft.Encryption);
    }

    [Fact]
    public void MissingObservationDoesNotBecomeAnImageChoice()
    {
        var model = new ConsumerConfiguration("wootc");
        Assert.Empty(model.Images);
        Assert.False(model.SelectImage("yellowfin"));
        Assert.Contains("authenticated image catalogue", model.InstallationBlockedReason);
        Assert.Throws<InvalidOperationException>(() => model.CreateDraft());
    }

    [Fact]
    public void CatalogueIdentityAndChannelControlsRejectAmbiguousChoices()
    {
        var model = Complete();
        foreach (var invalid in new[] {
            Catalogue() with { SchemaVersion = 2 }, Catalogue() with { BrandId = "bluefin" },
            Catalogue() with { Source = "guessed" }, Catalogue() with { MetadataSha256 = "unknown" },
            Catalogue() with { Channel = "future" }, Catalogue() with { Images = Array.Empty<ConfigurationImage>() },
            Catalogue() with { Images = new[] { Catalogue().Images[0], Catalogue().Images[0] } },
            Catalogue() with { Images = new[] { Catalogue().Images[0] with { ImageRef = "" } } },
            Catalogue() with { Images = new[] { Catalogue().Images[0] with { RequiresMokEnrollment = true } } }
        }) Assert.Throws<InvalidDataException>(() => model.ApplyCatalogue(invalid));
        Assert.Equal(Reference, model.SelectedImage!.ImageRef);
    }

    [Fact]
    public void CatalogueCopyPreservesObservedChoiceWhenCallerChangesItsArray()
    {
        var array = new[] { Catalogue().Images[0] };
        var model = new ConsumerConfiguration("wootc");
        model.ApplyCatalogue(Catalogue() with { Images = array });
        array[0] = array[0] with { ImageRef = "ghcr.io/tuna-os/other:latest" };
        Assert.True(model.SelectImage("yellowfin"));
        Assert.Equal(Reference, model.SelectedImage!.ImageRef);
    }

    [Theory]
    [InlineData("username", "Username must be lowercase")]
    [InlineData("password", "Passwords do not match")]
    [InlineData("hostname", "computer name")]
    [InlineData("disk", "20 GB")]
    [InlineData("encryption", "supported encryption")]
    [InlineData("luks", "Set a LUKS passphrase")]
    public void ActualFormFieldsExposeTheirBlockedReason(string field, string reason)
    {
        var model = Complete();
        switch (field)
        {
            case "username": model.Username = "Uppercase"; break;
            case "password": model.PasswordConfirmation = "different public fixture"; break;
            case "hostname": model.Hostname = "contains spaces"; break;
            case "disk": model.DiskSizeGb = 19; break;
            case "encryption": model.Encryption = "unknown"; break;
            case "luks": model.Encryption = "luks-passphrase"; break;
        }
        Assert.Contains(reason, model.InstallationBlockedReason);
        Assert.False(model.CanInstall);
        Assert.Throws<InvalidOperationException>(() => model.CreateDraft());
    }

    [Fact]
    public void MatchingDriveIdentityMapsExactImageAndConfigurationWithoutInstallReceipt()
    {
        var model = Complete();
        var result = model.ApplyDriveMapping(Directive(), "hosted-current");
        Assert.True(result.Mapped);
        Assert.False(result.ImageMismatch);
        Assert.False(result.InstallDriven);
        Assert.Equal("hosted-current", result.RunId);
        Assert.Equal("1234567890abcdef1234567890abcdef", result.DirectiveId);
        var draft = model.CreateDraft();
        Assert.Equal(Reference, draft.ImageRef);
        Assert.Equal("fixture", draft.Username);
        Assert.Equal(48, draft.DiskSizeGB);
        Assert.Equal("tpm2-luks", draft.Encryption);
        Assert.False(model.CanInstall);
        Assert.DoesNotContain("public fixture password", Directive().ToString());
    }

    [Fact]
    public void ImageMismatchCannotSelectDefaultOrChangePrivateConfiguration()
    {
        var model = Complete();
        var result = model.ApplyDriveMapping(Directive("ghcr.io/tuna-os/other:latest"), "hosted-current");
        Assert.False(result.Mapped);
        Assert.True(result.ImageMismatch);
        Assert.False(result.InstallDriven);
        Assert.Equal("linux_user", model.Username);
        Assert.Equal(Reference, model.SelectedImage!.ImageRef);
        Assert.Throws<InvalidOperationException>(() => model.CreateDraft());
        Assert.Throws<InvalidDataException>(() => model.ApplyDriveMapping(Directive(), "hosted-current"));
        Assert.Equal("linux_user", model.Username);
    }

    [Fact]
    public void MissingStorageObservationNeverDefaultsToC()
    {
        var model = Complete();
        model.ApplyCatalogue(Catalogue() with { Storage = Array.Empty<ConfigurationStorage>() });
        model.SelectImage("yellowfin");
        Assert.False(model.SelectStorage(StorageId));
        Assert.Contains("assessed storage", model.FormProblem);
        Assert.Throws<InvalidOperationException>(() => model.CreateDraft());
    }

    [Fact]
    public void EngineImageAdmissionRefusalBecomesTheDisabledReason()
    {
        var model = Complete();
        model.ApplyCatalogue(Catalogue() with { Images = new[] { Catalogue().Images[0] with {
            Admitted = false, AdmissionBlockedReason = "This image is not supported in this channel." } } });
        model.SelectImage("yellowfin");
        Assert.Equal("This image is not supported in this channel.", model.FormProblem);
        Assert.False(model.CanInstall);
    }

    [Fact]
    public void WrongRunAndReplayRefuseBeforeChangingFields()
    {
        var model = Complete();
        Assert.Throws<InvalidDataException>(() => model.ApplyDriveMapping(Directive(run: "old-run"), "hosted-current"));
        Assert.Equal("linux_user", model.Username);
        model.ApplyDriveMapping(Directive(), "hosted-current");
        model.Username = "user_choice";
        Assert.Throws<InvalidDataException>(() => model.ApplyDriveMapping(Directive(), "hosted-current"));
        Assert.Equal("user_choice", model.Username);
    }
}
