using System.Text.RegularExpressions;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

// View data comes from an authenticated configuration observation. It is not
// an independent image catalogue or authorization to change this computer.
public sealed record ConfigurationImage(string Id, string Name, string ImageRef, string Status,
    bool Admitted, string AdmissionBlockedReason, bool RequiresMokEnrollment, string MokEnrollment, bool ContentVerified);
public sealed record ConfigurationDefaults(int DiskSizeGb, string Encryption, string Bootloader, bool ComposeFs, bool WindowsLook);
public sealed record ConfigurationStorage(string Id, string DriveLetter, string DiskGuid, string PartitionGuid,
    string NtfsSerial, long FreeBytes, int MaximumRootDiskSizeGb);
public sealed record ConfigurationCatalogue(int SchemaVersion, string BrandId, string Source, string MetadataSha256,
    IReadOnlyList<ConfigurationImage> Images, string Channel, bool ExperimentalImages,
    ConfigurationDefaults Defaults, IReadOnlyList<ConfigurationStorage> Storage);

public sealed class InstallDriveMapping
{
    public int SchemaVersion { get; init; }
    public string RunId { get; init; } = "";
    public string DirectiveId { get; init; } = "";
    public string Action { get; init; } = "";
    public string ImageRef { get; init; } = "";
    public string Username { get; init; } = "";
    public string Password { get; init; } = "";
    public string Hostname { get; init; } = "";
    public int DiskSizeGb { get; init; }
    public string Encryption { get; init; } = "";
    public string StorageId { get; init; } = "";
    public string LuksPassphrase { get; init; } = "";
    public override string ToString() => "Native install directive (private configuration omitted)";
}

public sealed record DriveMappingObservation(string RunId, string DirectiveId, bool Mapped, bool ImageMismatch,
    bool InstallDriven, string BlockedReason);

public sealed class ConsumerConfiguration
{
    private readonly string brandId;
    private ConfigurationCatalogue? catalogue;
    private ConfigurationImage? selected;
    private ConfigurationStorage? storage;
    private readonly HashSet<string> mappedDirectives = new(StringComparer.Ordinal);
    public string Username { get; set; } = "";
    public string Password { private get; set; } = "";
    public string PasswordConfirmation { private get; set; } = "";
    public string Hostname { get; set; } = "";
    public int DiskSizeGb { get; set; }
    public string Encryption { get; set; } = "";
    public string LuksPassphrase { private get; set; } = "";
    public bool WindowsLook { get; set; }
    public bool ImageMismatch { get; private set; }
    public ConfigurationImage? SelectedImage => selected;
    public ConfigurationStorage? SelectedStorage => storage;
    public IReadOnlyList<ConfigurationImage> Images => catalogue?.Images ?? Array.Empty<ConfigurationImage>();
    // The configuration view cannot grant engine capabilities. A future
    // operation route must obtain and bind authorization separately.
    public bool CanInstall => false;
    public string InstallationBlockedReason => FormProblem.Length != 0 ? FormProblem :
        "This native preview cannot authorize installation or change storage.";

    public ConsumerConfiguration(string brandId)
    {
        if (string.IsNullOrWhiteSpace(brandId)) throw new ArgumentException("Brand identity is required");
        this.brandId = brandId;
    }

    public void ApplyCatalogue(ConfigurationCatalogue observation)
    {
        if (observation is null || observation.SchemaVersion != 1 || observation.BrandId != brandId ||
            observation.Source is not ("embedded" or "trusted-root") ||
            !Regex.IsMatch(observation.MetadataSha256 ?? "", "^[0-9a-f]{64}$") ||
            observation.Channel is not ("alpha" or "beta" or "stable") || observation.Images is null || observation.Images.Count is < 1 or > 256)
            throw new InvalidDataException("Configuration catalogue observation is unsupported");
        var images = observation.Images.ToArray();
        if (images.Any(image => image is null || string.IsNullOrWhiteSpace(image.Id) || string.IsNullOrWhiteSpace(image.Name) ||
            string.IsNullOrWhiteSpace(image.ImageRef) || image.Status is not ("green" or "experimental") ||
            (image.Admitted && image.AdmissionBlockedReason.Length != 0) ||
            (!image.Admitted && string.IsNullOrWhiteSpace(image.AdmissionBlockedReason)) ||
            (image.RequiresMokEnrollment != (image.MokEnrollment.Length != 0)) || image.MokEnrollment.Length > 32) ||
            images.Select(image => image.Id).Distinct(StringComparer.Ordinal).Count() != images.Length ||
            images.Select(image => image.ImageRef).Distinct(StringComparer.Ordinal).Count() != images.Length)
            throw new InvalidDataException("Configuration image identity is invalid or ambiguous");
        if (observation.Defaults is null || observation.Defaults.DiskSizeGb < 20 ||
            observation.Defaults.Encryption is not ("none" or "tpm2-luks" or "luks-passphrase") ||
            observation.Defaults.Bootloader is not ("auto" or "grub2" or "systemd-boot") || observation.Storage is null)
            throw new InvalidDataException("Configuration defaults or storage observations are missing");
        var volumes = observation.Storage.ToArray();
        if (volumes.Any(volume => volume is null || string.IsNullOrWhiteSpace(volume.Id) ||
            !Regex.IsMatch(volume.DriveLetter, "^[A-Z]$") || !Guid.TryParse(volume.DiskGuid, out _) ||
            !Guid.TryParse(volume.PartitionGuid, out _) || !Regex.IsMatch(volume.NtfsSerial, "^[0-9a-f]{16}$") ||
            volume.FreeBytes < 0 || volume.MaximumRootDiskSizeGb < 20) ||
            volumes.Select(volume => volume.Id).Distinct(StringComparer.Ordinal).Count() != volumes.Length ||
            volumes.Select(volume => volume.DriveLetter).Distinct(StringComparer.Ordinal).Count() != volumes.Length)
            throw new InvalidDataException("Storage identity or capacity observation is invalid");
        catalogue = observation with { Images = Array.AsReadOnly(images), Storage = Array.AsReadOnly(volumes) };
        DiskSizeGb = observation.Defaults.DiskSizeGb;
        Encryption = observation.Defaults.Encryption;
        WindowsLook = observation.Defaults.WindowsLook;
        storage = null;
        selected = null;
        ImageMismatch = false;
    }

    public bool SelectImage(string id)
    {
        selected = catalogue?.Images.SingleOrDefault(image => image.Id == id);
        ImageMismatch = false;
        return selected is not null;
    }

    public bool SelectStorage(string id)
    {
        storage = catalogue?.Storage.SingleOrDefault(volume => volume.Id == id);
        return storage is not null;
    }

    public string FormProblem
    {
        get
        {
            if (catalogue is null) return "Read the authenticated image catalogue before choosing Linux.";
            if (ImageMismatch) return "The requested image does not match an available variant.";
            if (selected is null) return "Choose a variant above.";
            if (!selected.Admitted) return selected.AdmissionBlockedReason;
            if (Username.Length == 0) return "Enter a Linux username.";
            if (!Regex.IsMatch(Username, "^[a-z_][a-z0-9_-]*$")) return "Username must be lowercase letters, digits, - or _.";
            if (Password.Length == 0) return "Set a password.";
            if (Password != PasswordConfirmation) return "Passwords do not match.";
            if (Hostname.Length != 0 && !Regex.IsMatch(Hostname, "^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$")) return "Choose a computer name with letters, digits, or hyphens.";
            if (DiskSizeGb < 20 || DiskSizeGb > 2048) return "Choose between 20 GB and 2048 GB for Linux.";
            if (Encryption is not ("none" or "tpm2-luks" or "luks-passphrase")) return "Choose a supported encryption option.";
            if (Encryption == "luks-passphrase" && LuksPassphrase.Length == 0) return "Set a LUKS passphrase, or switch to TPM or no encryption.";
            if (storage is null) return "Choose an assessed storage location for Linux.";
            if (DiskSizeGb > storage.MaximumRootDiskSizeGb) return "The selected volume does not have enough available space.";
            return "";
        }
    }

    public InstallConfig CreateDraft()
    {
        if (FormProblem.Length != 0) throw new InvalidOperationException("Linux configuration is incomplete");
        return new InstallConfig { ImageRef = selected!.ImageRef, Username = Username, Password = Password,
            Hostname = Hostname, DiskSizeGB = DiskSizeGb, Encryption = Encryption, LuksPassphrase = LuksPassphrase,
            WindowsLook = WindowsLook, Bootloader = catalogue!.Defaults.Bootloader,
            ComposeFs = catalogue.Defaults.ComposeFs, StorageDrive = storage!.DriveLetter };
    }

    public DriveMappingObservation ApplyDriveMapping(InstallDriveMapping directive, string currentRunId)
    {
        if (directive.SchemaVersion != 1 || directive.RunId.Length is < 1 or > 128 || directive.RunId != currentRunId ||
            !Regex.IsMatch(directive.DirectiveId, "^[0-9a-f]{32}$") || directive.Action != "install" ||
            mappedDirectives.Contains(directive.DirectiveId))
            throw new InvalidDataException("Drive directive identity is invalid or stale");
        mappedDirectives.Add(directive.DirectiveId);
        var requested = catalogue?.Images.SingleOrDefault(image => image.ImageRef == directive.ImageRef);
        if (requested is null)
        {
            ImageMismatch = true;
            return new(directive.RunId, directive.DirectiveId, false, true, false, InstallationBlockedReason);
        }
        var requestedStorage = catalogue?.Storage.SingleOrDefault(volume => volume.Id == directive.StorageId);
        if (requestedStorage is null) return new(directive.RunId, directive.DirectiveId, false, false, false,
            "The requested storage identity has not been observed.");
        selected = requested;
        storage = requestedStorage;
        ImageMismatch = false;
        Username = directive.Username;
        Password = directive.Password;
        PasswordConfirmation = directive.Password;
        Hostname = directive.Hostname;
        DiskSizeGb = directive.DiskSizeGb == 0 ? catalogue!.Defaults.DiskSizeGb : directive.DiskSizeGb;
        Encryption = directive.Encryption.Length == 0 ? catalogue!.Defaults.Encryption : directive.Encryption;
        LuksPassphrase = directive.LuksPassphrase;
        // Mapping a directive is not an Install click or a backend mutation.
        return new(directive.RunId, directive.DirectiveId, true, false, false, InstallationBlockedReason);
    }
}
