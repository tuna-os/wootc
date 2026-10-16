package main

import "fmt"

// nativeInstallPlanBinding is what an install intent stays bound to: one
// observed storage volume, by physical identity, and one admitted image.
type nativeInstallPlanBinding struct {
	volume   NativeConfigurationStorage
	imageRef string
}

// bindNativeInstallPlan accepts a plan only for a volume and an image that
// the engine itself observed and admitted. A drive letter the person typed is
// not enough: the volume's disk, partition and NTFS identity are recorded.
func bindNativeInstallPlan(snapshot NativeConfigurationSnapshot, plan InstallConfig) (nativeInstallPlanBinding, error) {
	var binding nativeInstallPlanBinding
	if snapshot.StorageStatus != "observed" {
		return binding, fmt.Errorf("the engine did not observe this computer's storage; read the Linux configuration again")
	}
	matches := 0
	for _, volume := range snapshot.Storage {
		if volume.DriveLetter == plan.StorageDrive {
			binding.volume = volume
			matches++
		}
	}
	if matches != 1 {
		return nativeInstallPlanBinding{}, fmt.Errorf("the chosen storage volume is not one the engine observed")
	}
	if plan.DiskSizeGB < 20 || plan.DiskSizeGB > binding.volume.MaximumRootDiskSizeGB {
		return nativeInstallPlanBinding{}, fmt.Errorf("the chosen volume does not have room for a %d GB Linux disk", plan.DiskSizeGB)
	}
	matches = 0
	var image NativeConfigurationImage
	for _, candidate := range snapshot.Images {
		if candidate.Image.ImageRef == plan.ImageRef {
			image = candidate
			matches++
		}
	}
	if matches != 1 {
		return nativeInstallPlanBinding{}, fmt.Errorf("the chosen image is not in the catalogue the engine observed")
	}
	if !image.Admitted {
		return nativeInstallPlanBinding{}, fmt.Errorf("%s", image.AdmissionBlockedReason)
	}
	binding.imageRef = image.Image.ImageRef
	return binding, nil
}

// unchangedIn re-binds the plan against a new observation and requires the
// same physical volume. A swapped disk or a reformatted volume refuses.
func (binding nativeInstallPlanBinding) unchangedIn(snapshot NativeConfigurationSnapshot, plan InstallConfig) error {
	current, err := bindNativeInstallPlan(snapshot, plan)
	if err != nil {
		return err
	}
	if current.volume.ID != binding.volume.ID || current.volume.DiskGUID != binding.volume.DiskGUID ||
		current.volume.PartitionGUID != binding.volume.PartitionGUID || current.volume.NtfsSerial != binding.volume.NtfsSerial ||
		current.imageRef != binding.imageRef {
		return fmt.Errorf("the chosen storage volume changed since the plan was checked")
	}
	return nil
}
