using Wootc.Shell.Engine;

namespace Wootc.Shell.Core;

// A projection of the authenticated DTO; engine policy remains authoritative.
public static class ConfigurationProjection
{
    public static ConfigurationCatalogue ToCatalogue(NativeConfigurationSnapshot snapshot) => new(
        snapshot.SchemaVersion, snapshot.BrandId, snapshot.CatalogueSource, snapshot.CatalogueMetadataSha256,
        snapshot.Images.Select(item => new ConfigurationImage(item.Image.Id, item.Image.Name, item.Image.ImageRef,
            item.Image.Status, item.Admitted, item.AdmissionBlockedReason, item.RequiresMokEnrollment,
            item.Image.MokEnroll ?? "", item.ContentVerified)).ToArray(), snapshot.Policy.Channel, snapshot.Policy.ExperimentalImages,
        new(snapshot.Defaults.DiskSizeGB, snapshot.Defaults.Encryption, snapshot.Defaults.Bootloader,
            snapshot.Defaults.ComposeFs, snapshot.Defaults.WindowsLook),
        snapshot.Storage.Select(volume => new ConfigurationStorage(volume.Id, volume.DriveLetter, volume.DiskGuid,
            volume.PartitionGuid, volume.NtfsSerial, volume.FreeBytes, volume.MaximumRootDiskSizeGB)).ToArray());
}
