package slurp

import (
	"fmt"
	"io"
	"os"
)

// Runner runs the external commands the offline pipeline needs: lsblk,
// mount, umount, cp, chown, chmod and restorecon. Run discards output;
// Output returns stdout.
type Runner interface {
	Run(name string, args ...string) error
	Output(name string, args ...string) ([]byte, error)
}

// Progress receives human-readable progress: Substep for a unit of work
// starting, Info for a result or warning.
type Progress interface {
	Substep(msg string)
	Info(msg string)
}

// Default locations. /run is tmpfs: the scratch copy survives the disk wipe
// between extraction and injection and is freed on reboot.
const (
	DefaultScratchBase    = "/run/fisherman-slurp"
	DefaultMountPoint     = "/run/fisherman-slurp-mnt"
	DefaultScanMountPoint = "/run/fisherman-slurp-scan"
	DefaultScratchFS      = "/run"
)

// ScratchReserve is how much of the scratch filesystem ExtractData leaves
// free for the system.
const ScratchReserve int64 = 2 * 1024 * 1024 * 1024

// Slurper reads user data off a Windows disk from Linux before it is
// partitioned, and writes it into the installed system afterwards. Use
// NewSlurper for the defaults; every field may be changed before use.
type Slurper struct {
	// Runner runs every external command. Required.
	Runner Runner
	// Progress receives progress lines; nil discards them.
	Progress Progress
	// Warnings receives non-fatal warnings from InjectWallpapers; nil
	// discards them. NewSlurper sets os.Stderr.
	Warnings io.Writer

	// ScratchBase holds the extracted data between extraction and
	// injection (data/ and wallpapers/ under it).
	ScratchBase string
	// MountPoint is where the extract steps mount the NTFS partition.
	MountPoint string
	// ScanMountPoint is where Scan mounts each NTFS partition.
	ScanMountPoint string
	// ScratchFS is the filesystem whose free space bounds ExtractData.
	ScratchFS string
	// Available reports the bytes available to an unprivileged writer on
	// the filesystem holding path. NewSlurper sets a statfs(2) observation.
	Available func(path string) (int64, error)
}

// NewSlurper returns a Slurper with the default scratch and mount paths,
// running commands through r and reporting to p (which may be nil).
func NewSlurper(r Runner, p Progress) *Slurper {
	return &Slurper{
		Runner:         r,
		Progress:       p,
		Warnings:       os.Stderr,
		ScratchBase:    DefaultScratchBase,
		MountPoint:     DefaultMountPoint,
		ScanMountPoint: DefaultScanMountPoint,
		ScratchFS:      DefaultScratchFS,
		Available:      statfsAvailable,
	}
}

func (s *Slurper) substep(msg string) {
	if s.Progress != nil {
		s.Progress.Substep(msg)
	}
}

func (s *Slurper) info(msg string) {
	if s.Progress != nil {
		s.Progress.Info(msg)
	}
}

func (s *Slurper) warnf(format string, args ...any) {
	if s.Warnings != nil {
		_, _ = fmt.Fprintf(s.Warnings, format, args...)
	}
}

// mountNTFS mounts partition read-only at mountPoint, with the kernel ntfs3
// driver or, failing that, ntfs-3g.
func (s *Slurper) mountNTFS(partition, mountPoint string) (ntfs3, ntfs3g error) {
	ntfs3 = s.Runner.Run("mount", "-t", "ntfs3", "-o", "ro,noatime", partition, mountPoint)
	if ntfs3 == nil {
		return nil, nil
	}
	return ntfs3, s.Runner.Run("mount", "-t", "ntfs-3g", "-o", "ro,noatime", partition, mountPoint)
}

// AvailableScratchBytes returns how much of the scratch filesystem
// ExtractData may fill: what is available, less ScratchReserve. It is 0 when
// the observation fails or nothing is left above the reserve.
func (s *Slurper) AvailableScratchBytes() int64 {
	if s.Available == nil {
		return 0
	}
	available, err := s.Available(s.ScratchFS)
	if err != nil || available <= ScratchReserve {
		return 0
	}
	return available - ScratchReserve
}
