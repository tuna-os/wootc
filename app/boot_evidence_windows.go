//go:build windows

package main

import (
	"encoding/binary"
	"fmt"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
)

// NTFS uses the full 64-bit volume serial as its Linux UUID. GetVolumeInformation
// returns only 32 bits and cannot establish the cross-OS host-volume identity.
// https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ns-winioctl-ntfs_volume_data_buffer
func ntfsHostUUID(drive string) (string, error) {
	if len(drive) != 1 || !strings.Contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", strings.ToUpper(drive)) {
		return "", fmt.Errorf("invalid host drive")
	}
	p, err := windows.UTF16PtrFromString(`\\.\` + strings.ToUpper(drive) + ":")
	if err != nil {
		return "", err
	}
	h, err := windows.CreateFile(p, windows.GENERIC_READ, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return "", err
	}
	defer windows.CloseHandle(h)
	var data [96]byte
	var returned uint32
	if err := windows.DeviceIoControl(h, 0x00090064, nil, 0, &data[0], uint32(len(data)), &returned, nil); err != nil {
		return "", err
	}
	if returned < 96 {
		return "", fmt.Errorf("truncated NTFS volume data")
	}
	return fmt.Sprintf("%016X", binary.LittleEndian.Uint64(data[:8])), nil
}

// installedLinuxEvidence is the verified first boot of this installation: the
// same cross-check status uses (assessFirstBootAt), plus the facts only a
// running Windows can observe now: the staged ESP is still this PC's ESP and
// the host volume is still the one Linux reported.
func installedLinuxEvidence(drive string) (*FirstBootAssessment, error) {
	if drive == "" {
		return nil, fmt.Errorf("host drive is absent")
	}
	root := strings.ToUpper(drive) + `:\wootc`
	if err := auditTrustedStateDirectory(root); err != nil {
		return nil, err
	}
	state, ok := readStateFrom(filepath.Join(root, "state.json"))
	if !ok || state.State != StateHealthy {
		return nil, fmt.Errorf("Linux has not reported a healthy boot")
	}
	var plan InstallationIdentity
	if err := readBootRecord(filepath.Join(root, "install", "installation.json"), &plan); err != nil {
		return nil, err
	}
	if err := validateInstallationIdentity(plan); err != nil {
		return nil, err
	}
	assessment := assessFirstBootAt(root)
	if assessment.Verdict != FirstBootVerified {
		return nil, fmt.Errorf("first boot is %s: %s", assessment.Verdict, assessment.Reason)
	}
	if canonicalGUID(findESPPartitionGuid()) != canonicalGUID(plan.EspPartitionGuid) {
		return nil, fmt.Errorf("the staged ESP is no longer this PC's ESP")
	}
	currentHost, err := ntfsHostUUID(drive)
	if err != nil {
		return nil, err
	}
	if !strings.EqualFold(currentHost, plan.HostUUID) {
		return nil, fmt.Errorf("the host volume is no longer the installation's volume")
	}
	return &assessment, nil
}

func verifyReportedLinuxHealth() error {
	drive := filepath.VolumeName(wootcDir())
	_, err := installedLinuxEvidence(strings.TrimSuffix(drive, ":"))
	return err
}
