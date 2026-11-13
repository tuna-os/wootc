package slurp

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// ScanResult describes the Windows data available for migration on a disk.
// Emitted as JSON by `fisherman scan <disk>` for the GUI to display.
type ScanResult struct {
	Disk       string         `json:"disk"`
	Partitions []NTFSPartScan `json:"partitions"`
}

// NTFSPartScan describes a single NTFS partition's available user data.
type NTFSPartScan struct {
	Partition  string     `json:"partition"`
	Users      []UserScan `json:"users"`
	TotalBytes int64      `json:"totalBytes"`
}

// UserScan describes one Windows user profile's available data.
type UserScan struct {
	Name       string         `json:"name"`
	Categories []CategoryScan `json:"categories"`
	TotalBytes int64          `json:"totalBytes"`
}

// CategoryScan describes one data category (Documents, Pictures, etc.)
type CategoryScan struct {
	Name  string `json:"name"`
	Path  string `json:"path"` // relative to user profile
	Bytes int64  `json:"bytes"`
	Count int    `json:"count"` // number of files
}

// DetectNTFS finds NTFS partitions on the given disk device.
// Returns partition device paths (e.g. ["/dev/nvme0n1p3"]).
func (s *Slurper) DetectNTFS(disk string) ([]string, error) {
	out, err := s.Runner.Output("lsblk", "-nrpo", "NAME,FSTYPE", disk)
	if err != nil {
		return nil, fmt.Errorf("lsblk: %w", err)
	}

	var ntfsPartitions []string
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[1] == "ntfs" {
			ntfsPartitions = append(ntfsPartitions, fields[0])
		}
	}
	return ntfsPartitions, nil
}

// Scan mounts the NTFS partitions on a disk read-only and enumerates available
// user data for migration. Returns a ScanResult suitable for JSON serialization
// to the GUI. Does NOT extract any data — just measures what's available.
func (s *Slurper) Scan(disk string) (*ScanResult, error) {
	result := &ScanResult{Disk: disk}

	ntfsPartitions, err := s.DetectNTFS(disk)
	if err != nil {
		return result, err
	}
	if len(ntfsPartitions) == 0 {
		return result, nil // no NTFS found — not an error
	}

	if err := os.MkdirAll(s.ScanMountPoint, 0o755); err != nil {
		return result, fmt.Errorf("creating scan mount point: %w", err)
	}
	defer func() { _ = os.Remove(s.ScanMountPoint) }()

	for _, part := range ntfsPartitions {
		partScan, err := s.scanPartition(part, s.ScanMountPoint)
		if err != nil {
			continue // skip unreadable partitions
		}
		if len(partScan.Users) > 0 {
			result.Partitions = append(result.Partitions, *partScan)
		}
	}

	return result, nil
}

// scanPartition mounts one NTFS partition and enumerates its user data.
func (s *Slurper) scanPartition(partition, mountPoint string) (*NTFSPartScan, error) {
	if e1, e2 := s.mountNTFS(partition, mountPoint); e1 != nil && e2 != nil {
		return nil, fmt.Errorf("mount failed")
	}
	defer func() {
		_ = s.Runner.Run("umount", mountPoint)
	}()

	result := &NTFSPartScan{Partition: partition}

	usersDir := filepath.Join(mountPoint, UsersDir)
	profiles, err := Profiles(usersDir)
	if err != nil {
		return nil, fmt.Errorf("no Users directory")
	}

	for _, name := range profiles {
		userScan := scanUserProfile(name, filepath.Join(usersDir, name))
		if userScan.TotalBytes > 0 {
			result.Users = append(result.Users, *userScan)
			result.TotalBytes += userScan.TotalBytes
		}
	}

	return result, nil
}

// scanUserProfile measures data in each category for one Windows user.
func scanUserProfile(name, profileDir string) *UserScan {
	user := &UserScan{Name: name}

	for _, cat := range categories {
		catDir := filepath.Join(profileDir, filepath.FromSlash(cat.Path))
		info, err := os.Stat(catDir)
		if err != nil || !info.IsDir() {
			continue
		}

		var bytes int64
		var count int
		_ = filepath.Walk(catDir, func(_ string, fi os.FileInfo, err error) error {
			if err != nil || fi.IsDir() {
				return nil //nolint:nilerr // best-effort: absent/unreadable source → skip, continue
			}
			bytes += fi.Size()
			count++
			return nil
		})

		if bytes > 0 {
			user.Categories = append(user.Categories, CategoryScan{
				Name:  cat.Name,
				Path:  cat.Path,
				Bytes: bytes,
				Count: count,
			})
			user.TotalBytes += bytes
		}
	}

	return user
}

// ScanJSON runs Scan and returns the result as indented JSON (the
// `fisherman scan` output).
func (s *Slurper) ScanJSON(disk string) (string, error) {
	result, err := s.Scan(disk)
	if err != nil {
		return "", err
	}
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data), nil
}
