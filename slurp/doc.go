// Package slurp is the Windows data-migration knowledge shared by wootc and
// fisherman: what a Windows user profile holds that is worth bringing to
// Linux, where it lives on the volume, and how to move it.
//
// It has two halves.
//
// The platform-neutral half needs only a path to a Windows volume (mounted
// read-only by fisherman, bridged at /run/wootc/host by wootc, or C:\ on a
// running Windows): the user-folder categories (Categories, UserFolders,
// CategoryPath), profile discovery and selection (Profiles, ResolveProfile),
// the wallpaper source paths, the BCP-47 → XKB and Windows → IANA time zone
// maps, and the Go shape of the look bundle wootc writes before it reboots
// (Look, PinnedApp, BundleDir, LookFile).
//
// The offline half (Slurper) is what an installer running on Linux does to a
// Windows disk it is about to overwrite: find the NTFS partitions, measure
// what each profile holds (Scan, ScanJSON), copy the user's choice into
// RAM-backed scratch before partitioning (ExtractData, ExtractWallpapers), and
// copy it into the installed system afterwards (InjectData,
// InjectWallpapers). It runs no command itself: the caller supplies a Runner
// (mount, umount, lsblk, cp, chown, chmod, restorecon) and, optionally, a
// Progress sink.
//
// The module uses only the standard library and imports neither wootc nor
// fisherman, so either can depend on it.
package slurp
