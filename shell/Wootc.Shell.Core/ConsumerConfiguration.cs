using System.Text.RegularExpressions;
using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

// View data comes from an authenticated configuration observation. It is not
// an independent image catalogue or authorization to change this computer.
public sealed record ConfigurationImage(string Id, string Name, string ImageRef, string Status,
    bool Admitted, string AdmissionBlockedReason, bool RequiresMokEnrollment, string MokEnrollment, bool ContentVerified,
    string DesktopName = "", string Base = "");
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

// What one image needs on one drive beside its Linux disk until the deploy
// ends (the engine's InstallSpace, GetNativeInstallSpace). SizeSource
// "unavailable" means the engine did not answer and the form assumes the
// smallest image's reserve, as the Wails launchpad does.
public sealed record ConfigurationInstallSpace(string ImageRef, string StorageDrive, int ReserveGb, string SizeSource);

public sealed class ConsumerConfiguration
{
    // Windows keeps this much free on its drive after the Linux disk lands
    // (the Wails launchpad's DISK_HEADROOM_GB).
    public const int WindowsHeadroomGb = 15;
    // The smallest image's reserve: the engine's minimumInstallReserveGiB and
    // the launchpad's MIN_INSTALL_RESERVE_GB.
    public const int MinimumInstallReserveGb = 22;
    private readonly string brandId;
    private readonly Dictionary<(string ImageRef, string StorageDrive), ConfigurationInstallSpace> installSpaces = new();
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
    // Null until the authenticated configuration has been read.
    public IReadOnlyList<ConfigurationStorage>? ObservedStorage => catalogue?.Storage;
    // The configuration view cannot grant engine capabilities. A future
    // operation route must obtain and bind authorization separately.
    public bool CanInstall => false;
    public string InstallationBlockedReason => FormProblem.Length != 0 ? FormProblem :
        "Check this plan with the engine before you install.";

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
        installSpaces.Clear();
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

    // The image and drive whose install space the form still needs, or null.
    public (string ImageRef, string StorageDrive)? PendingInstallSpace =>
        selected is null || storage is null || InstallSpaceFor(selected, storage) is not null ? null : (selected.ImageRef, storage.DriveLetter);

    private ConfigurationInstallSpace? InstallSpaceFor(ConfigurationImage image, ConfigurationStorage volume) =>
        installSpaces.TryGetValue((image.ImageRef, volume.DriveLetter), out var space) ? space : null;

    // The engine's answer for one image and drive, kept per pair so a late
    // answer for an earlier choice never stands in for the current one. The
    // disk size is lowered to fit, as the launchpad does.
    public void ApplyInstallSpace(ConfigurationInstallSpace space)
    {
        if (space is null || catalogue is null || space.ReserveGb is < MinimumInstallReserveGb or > 4096 ||
            !catalogue.Images.Any(image => image.ImageRef == space.ImageRef) ||
            !catalogue.Storage.Any(volume => volume.DriveLetter == space.StorageDrive) ||
            space.SizeSource is not ("bundle" or "registry" or "default" or "unavailable"))
            throw new InvalidDataException("Install space observation is unsupported");
        installSpaces[(space.ImageRef, space.StorageDrive)] = space;
        FitDiskSize();
    }

    // No answer from the engine: assume the smallest image's reserve rather
    // than hold the form forever. The engine still refuses what does not fit.
    public void InstallSpaceUnavailable(string imageRef, string storageDrive) =>
        ApplyInstallSpace(new(imageRef, storageDrive, MinimumInstallReserveGb, "unavailable"));

    // What stays free beside the Linux disk: the reserve is given back when
    // the install ends, so it and Windows' headroom share the same space.
    public int? KeptFreeGb => selected is null || storage is null || InstallSpaceFor(selected, storage) is not { } space ? null
        : Math.Max(WindowsHeadroomGb, space.ReserveGb);

    // The largest Linux disk the selected drive can hold, or null until its
    // install space is known.
    public int? MaximumDiskSizeGb => KeptFreeGb is not int kept ? null
        : (int)Math.Min(storage!.MaximumRootDiskSizeGb, storage.FreeBytes / (1L << 30) - kept);

    private void FitDiskSize()
    {
        if (MaximumDiskSizeGb is int largest && DiskSizeGb > largest && largest >= 20) DiskSizeGb = largest / 5 * 5;
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
            if (MaximumDiskSizeGb is not int largest) return $"Checking how much working space {selected.Name} needs while it installs.";
            long freeGb = storage.FreeBytes / (1L << 30);
            if (largest < 20)
                return $"{storage.DriveLetter}: has {freeGb} GB free, and {KeptFreeReason()} has to stay free beside the Linux disk. Free up space first.";
            if (DiskSizeGb > largest)
                return $"{storage.DriveLetter}: has {freeGb} GB free, and {KeptFreeReason()} has to stay free beside the Linux disk. Choose {largest} GB or less, or free up space first.";
            return "";
        }
    }

    private string KeptFreeReason()
    {
        int reserve = InstallSpaceFor(selected!, storage!)!.ReserveGb;
        return reserve > WindowsHeadroomGb
            ? $"about {reserve} GB of working space to unpack {selected!.Name} during the install (given back when it finishes)"
            : $"the {WindowsHeadroomGb} GB Windows needs to keep working";
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
        // The directive must name its target volume; one observed volume is
        // never taken as the answer (E2EDriveTarget).
        ConfigurationStorage requestedStorage;
        try
        {
            requestedStorage = E2EDriveTarget.Resolve(directive.StorageId, catalogue?.Storage ?? Array.Empty<ConfigurationStorage>());
        }
        catch (E2EDriveRefusal refusal)
        {
            return new(directive.RunId, directive.DirectiveId, false, false, false, refusal.Message);
        }
        selected = requested;
        storage = requestedStorage;
        ImageMismatch = false;
        Username = directive.Username;
        Password = directive.Password;
        PasswordConfirmation = directive.Password;
        Hostname = directive.Hostname;
        DiskSizeGb = directive.DiskSizeGb == 0 ? catalogue!.Defaults.DiskSizeGb : directive.DiskSizeGb;
        // As a person's form: the size never exceeds what the drive can hold
        // beside the image's install space, once that is known.
        FitDiskSize();
        // As the Wails drive loop does (directive.encryption || 'none'): a
        // directive that names no encryption installs unencrypted.
        Encryption = directive.Encryption.Length == 0 ? "none" : directive.Encryption;
        LuksPassphrase = directive.LuksPassphrase;
        // Mapping a directive is not an Install click or a backend mutation.
        return new(directive.RunId, directive.DirectiveId, true, false, false, InstallationBlockedReason);
    }
}
