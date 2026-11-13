package slurp

// Tests for the NTFS scan pipeline (scan.go): DetectNTFS output parsing,
// per-user category enumeration, per-partition mount+enumeration, and the
// full Scan orchestration. They run against the recording Runner of
// helpers_test.go, so no root, no real NTFS partition, and no /run access
// are needed.

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
}

// --- DetectNTFS ---

func TestDetectNTFS_ParsesLsblk(t *testing.T) {
	stubOutput(t, []byte("/dev/sda1 vfat\n/dev/sda2 ntfs\n/dev/sda3 ntfs\n/dev/sda4 ext4\n"))
	parts, err := sl(t).DetectNTFS("/dev/sda")
	if err != nil {
		t.Fatalf("DetectNTFS: %v", err)
	}
	want := []string{"/dev/sda2", "/dev/sda3"}
	if len(parts) != len(want) {
		t.Fatalf("partitions = %v, want %v", parts, want)
	}
	for i := range want {
		if parts[i] != want[i] {
			t.Errorf("parts[%d] = %q, want %q", i, parts[i], want[i])
		}
	}
}

func TestDetectNTFS_NoNTFSIsNotAnError(t *testing.T) {
	stubOutput(t, []byte("/dev/sda1 vfat\n/dev/sda2 ext4\n"))
	parts, err := sl(t).DetectNTFS("/dev/sda")
	if err != nil || len(parts) != 0 {
		t.Errorf("no-NTFS: parts=%v err=%v, want empty and nil", parts, err)
	}
}

func TestDetectNTFS_EmptyOutput(t *testing.T) {
	stubOutput(t, nil)
	parts, err := sl(t).DetectNTFS("/dev/sda")
	if err != nil || len(parts) != 0 {
		t.Errorf("empty output: parts=%v err=%v, want empty and nil", parts, err)
	}
}

func TestDetectNTFS_SkipsMalformedLine(t *testing.T) {
	// A line without an fstype field (e.g. a raw device) must not crash.
	stubOutput(t, []byte("/dev/sda1 ntfs\n/dev/sdb\n"))
	parts, err := sl(t).DetectNTFS("/dev/sda")
	if err != nil {
		t.Fatalf("DetectNTFS: %v", err)
	}
	if len(parts) != 1 || parts[0] != "/dev/sda1" {
		t.Errorf("parts = %v, want [/dev/sda1]", parts)
	}
}

func TestDetectNTFS_PropagatesLsblkError(t *testing.T) {
	fake(t).outErr = errors.New("lsblk: no such device")

	_, err := sl(t).DetectNTFS("/dev/nope")
	if err == nil || !strings.Contains(err.Error(), "lsblk") {
		t.Errorf("err = %v, want an lsblk-wrapped error", err)
	}
}

// --- scanUserProfile ---

func TestScanUserProfile_CountsBytesAndFiles(t *testing.T) {
	prof := t.TempDir()
	writeFile(t, filepath.Join(prof, "Documents", "a.txt"), 100)
	writeFile(t, filepath.Join(prof, "Documents", "sub", "b.md"), 40)
	writeFile(t, filepath.Join(prof, "Pictures", "img.png"), 1000)
	writeFile(t, filepath.Join(prof, "Music", "song.mp3"), 0) // empty file: bytes 0

	user := scanUserProfile("Alice", prof)
	if user.Name != "Alice" {
		t.Errorf("name = %q, want Alice", user.Name)
	}
	if user.TotalBytes != 100+40+1000 {
		t.Errorf("TotalBytes = %d, want %d", user.TotalBytes, 1140)
	}
	if len(user.Categories) != 2 {
		t.Fatalf("categories = %d, want 2 (Documents, Pictures) — Music has 0 bytes", len(user.Categories))
	}
	byName := map[string]CategoryScan{}
	for _, c := range user.Categories {
		byName[c.Name] = c
	}
	if doc := byName["Documents"]; doc.Bytes != 140 || doc.Count != 2 {
		t.Errorf("Documents = %+v, want bytes=140 count=2", doc)
	}
	if pic := byName["Pictures"]; pic.Bytes != 1000 || pic.Count != 1 {
		t.Errorf("Pictures = %+v, want bytes=1000 count=1", pic)
	}
	if byName["Documents"].Path != "Documents" {
		t.Errorf("Documents path = %q, want %q", byName["Documents"].Path, "Documents")
	}
}

func TestScanUserProfile_NestedWallpapersPath(t *testing.T) {
	prof := t.TempDir()
	writeFile(t, filepath.Join(prof, "AppData", "Roaming", "Microsoft", "Windows", "Themes", "wall.jpg"), 500)

	user := scanUserProfile("Alice", prof)
	if user.TotalBytes != 500 {
		t.Errorf("TotalBytes = %d, want 500", user.TotalBytes)
	}
	if len(user.Categories) != 1 || user.Categories[0].Name != "Wallpapers" {
		t.Fatalf("categories = %+v, want a single Wallpapers category", user.Categories)
	}
	if user.Categories[0].Path != "AppData/Roaming/Microsoft/Windows/Themes" {
		t.Errorf("Wallpapers path = %q", user.Categories[0].Path)
	}
}

func TestScanUserProfile_NoKnownCategories(t *testing.T) {
	prof := t.TempDir()
	writeFile(t, filepath.Join(prof, "SomethingElse", "x.dat"), 10)

	user := scanUserProfile("Bob", prof)
	if user.TotalBytes != 0 || len(user.Categories) != 0 {
		t.Errorf("unexpected data for unknown dirs: %+v", user)
	}
}

func TestScanUserProfile_MissingProfileDir(t *testing.T) {
	user := scanUserProfile("Ghost", filepath.Join(t.TempDir(), "nope"))
	if user.TotalBytes != 0 || len(user.Categories) != 0 {
		t.Errorf("missing profile dir should yield nothing: %+v", user)
	}
}

// --- scanPartition ---

func TestScanPartition_EnumeratesUsers(t *testing.T) {
	mountPoint := t.TempDir()
	users := filepath.Join(mountPoint, "Users")
	writeFile(t, filepath.Join(users, "Alice", "Documents", "a.txt"), 10)
	// Skipped profiles and files must not appear as users.
	writeFile(t, filepath.Join(users, "Public", "shared.txt"), 50)
	writeFile(t, filepath.Join(users, "Default", "d.txt"), 50)
	writeFile(t, filepath.Join(users, "Default User", "d.txt"), 50)
	writeFile(t, filepath.Join(users, "All Users", "d.txt"), 50)
	writeFile(t, filepath.Join(users, "desktop.ini"), 50)
	writeFile(t, filepath.Join(users, ".hidden", "h.txt"), 50)
	writeFile(t, filepath.Join(users, "plainfile.txt"), 50)

	calls := stubRun(t)
	part, err := sl(t).scanPartition("/dev/sda2", mountPoint)
	if err != nil {
		t.Fatalf("scanPartition: %v", err)
	}
	if len(part.Users) != 1 || part.Users[0].Name != "Alice" {
		t.Fatalf("users = %+v, want only Alice", part.Users)
	}
	if part.Users[0].TotalBytes != 10 {
		t.Errorf("Alice total = %d, want 10", part.Users[0].TotalBytes)
	}
	if part.TotalBytes != 10 {
		t.Errorf("partition total = %d, want 10", part.TotalBytes)
	}
	if part.Partition != "/dev/sda2" {
		t.Errorf("partition = %q", part.Partition)
	}
	// The mount and the deferred umount must both have run.
	mountSeen, umountSeen := false, false
	for _, c := range calls() {
		if strings.Contains(c, "mount ") {
			mountSeen = true
		}
		if strings.HasPrefix(c, "umount ") {
			umountSeen = true
		}
	}
	if !mountSeen || !umountSeen {
		t.Errorf("expected a mount and umount, calls: %v", calls())
	}
}

func TestScanPartition_MountFallbackToNtfs3g(t *testing.T) {
	mountPoint := t.TempDir()
	writeFile(t, filepath.Join(mountPoint, "Users", "Alice", "Documents", "a.txt"), 10)

	stubRun(t, "mount -t ntfs3") // first driver fails, ntfs-3g succeeds
	part, err := sl(t).scanPartition("/dev/sda3", mountPoint)
	if err != nil {
		t.Fatalf("scanPartition with fallback: %v", err)
	}
	if len(part.Users) != 1 {
		t.Errorf("users = %+v, want Alice after ntfs-3g fallback", part.Users)
	}
}

func TestScanPartition_MountBothFail(t *testing.T) {
	mountPoint := t.TempDir()
	writeFile(t, filepath.Join(mountPoint, "Users", "Alice", "Documents", "a.txt"), 10)

	stubRun(t, "mount -t ntfs3", "mount -t ntfs-3g")
	_, err := sl(t).scanPartition("/dev/sda4", mountPoint)
	if err == nil || !strings.Contains(err.Error(), "mount failed") {
		t.Errorf("err = %v, want mount failed", err)
	}
}

func TestScanPartition_NoUsersDirectory(t *testing.T) {
	mountPoint := t.TempDir()
	writeFile(t, filepath.Join(mountPoint, "Windows", "win.ini"), 10)

	stubRun(t)
	_, err := sl(t).scanPartition("/dev/sda5", mountPoint)
	if err == nil || !strings.Contains(err.Error(), "no Users directory") {
		t.Errorf("err = %v, want no Users directory", err)
	}
}

// --- Scan (full orchestration) ---

func TestScan_FullPipeline(t *testing.T) {
	mountPoint := t.TempDir()
	withScanMountPoint(t, mountPoint)

	// Two NTFS partitions must see *different* data (a real mount replaces
	// the mount-point contents). The mount mock swaps the Users tree in
	// based on which partition is being "mounted".
	aliceUsers := filepath.Join(t.TempDir(), "Users")
	writeFile(t, filepath.Join(aliceUsers, "Alice", "Documents", "a.txt"), 100)
	bobUsers := filepath.Join(t.TempDir(), "Users")
	writeFile(t, filepath.Join(bobUsers, "Bob", "Pictures", "p.png"), 200)

	fake(t).onRun = func(name string, args []string) {
		if name == "mount" {
			joined := strings.Join(args, " ")
			users := filepath.Join(mountPoint, "Users")
			_ = os.RemoveAll(users)
			switch {
			case strings.Contains(joined, "/dev/sda2"):
				copyTree(t, aliceUsers, users)
			case strings.Contains(joined, "/dev/sda3"):
				copyTree(t, bobUsers, users)
			}
		}
	}

	stubOutput(t, []byte("/dev/sda1 vfat\n/dev/sda2 ntfs\n/dev/sda3 ntfs\n"))

	res, err := sl(t).Scan("/dev/sda")
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if res.Disk != "/dev/sda" {
		t.Errorf("disk = %q", res.Disk)
	}
	if len(res.Partitions) != 2 {
		t.Fatalf("partitions = %d, want 2", len(res.Partitions))
	}
	names := map[string]bool{}
	total := int64(0)
	for _, p := range res.Partitions {
		for _, u := range p.Users {
			names[u.Name] = true
			total += u.TotalBytes
		}
	}
	if !names["Alice"] || !names["Bob"] || len(names) != 2 {
		t.Errorf("users = %v, want Alice and Bob only", names)
	}
	if total != 300 {
		t.Errorf("grand total = %d, want 300", total)
	}
}

// copyTree recursively copies src into dst (created if needed).
func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.Walk(src, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if fi.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, 0o644)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestScan_NoNTFSPartitions(t *testing.T) {
	stubOutput(t, []byte("/dev/sda1 vfat\n/dev/sda2 ext4\n"))
	res, err := sl(t).Scan("/dev/sda")
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(res.Partitions) != 0 {
		t.Errorf("partitions = %v, want none", res.Partitions)
	}
}

func TestScan_SkipsUnreadablePartitions(t *testing.T) {
	mountPoint := t.TempDir()
	withScanMountPoint(t, mountPoint)
	writeFile(t, filepath.Join(mountPoint, "Users", "Alice", "Documents", "a.txt"), 100)

	// First NTFS partition mounts OK; the second fails entirely.
	stubOutput(t, []byte("/dev/sda2 ntfs\n/dev/sda3 ntfs\n"))
	stubRun(t, "/dev/sda3")

	res, err := sl(t).Scan("/dev/sda")
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(res.Partitions) != 1 {
		t.Fatalf("partitions = %d, want 1 (the unreadable one skipped)", len(res.Partitions))
	}
}

func TestScanJSON_SerializesResult(t *testing.T) {
	mountPoint := t.TempDir()
	withScanMountPoint(t, mountPoint)
	writeFile(t, filepath.Join(mountPoint, "Users", "Alice", "Documents", "a.txt"), 100)

	stubOutput(t, []byte("/dev/sda2 ntfs\n"))
	stubRun(t)

	js, err := sl(t).ScanJSON("/dev/sda")
	if err != nil {
		t.Fatalf("ScanJSON: %v", err)
	}
	for _, want := range []string{`"disk": "/dev/sda"`, `"partition": "/dev/sda2"`, `"name": "Alice"`, `"totalBytes"`} {
		if !strings.Contains(js, want) {
			t.Errorf("JSON missing %q:\n%s", want, js)
		}
	}
}
