package slurp

// Tests for the data/wallpaper extraction + injection half (data.go,
// wallpaper.go). Everything filesystem-shaped runs against temp dirs; the
// external seams are the Slurper's Runner and its scratch capacity
// observation (Available), stubbed in helpers_test.go. No root, no NTFS
// partition, no /run access needed.

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func writeFixture(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
}

// --- extractFromProfile / extractFromDir helpers ---

func TestExtractFromProfile_TranscodedWallpaper(t *testing.T) {
	profile := t.TempDir()
	target := t.TempDir()
	// A real wallpaper-sized TranscodedWallpaper is copied.
	writeFixture(t, filepath.Join(profile,
		"AppData", "Roaming", "Microsoft", "Windows", "Themes", "TranscodedWallpaper"), 200*1024)

	count := extractFromProfile(profile, target)
	if count != 1 {
		t.Fatalf("count = %d, want 1", count)
	}
	if _, err := os.Stat(filepath.Join(target, "TranscodedWallpaper")); err != nil {
		t.Errorf("TranscodedWallpaper not copied: %v", err)
	}
}

func TestExtractFromProfile_SkipsTinyTranscodedWallpaper(t *testing.T) {
	profile := t.TempDir()
	target := t.TempDir()
	writeFixture(t, filepath.Join(profile,
		"AppData", "Roaming", "Microsoft", "Windows", "Themes", "TranscodedWallpaper"), 1024)

	if count := extractFromProfile(profile, target); count != 0 {
		t.Errorf("count = %d, want 0 (file <10KB is not a wallpaper)", count)
	}
}

func TestExtractFromProfile_SpotlightAssetsWithoutExtension(t *testing.T) {
	profile := t.TempDir()
	target := t.TempDir()
	assets := filepath.Join(profile,
		"AppData", "Local", "Packages",
		"Microsoft.Windows.ContentDeliveryManager_cw5n1h2txyewy", "LocalState", "Assets")
	// Ext-less file, plausible wallpaper size -> renamed .jpg.
	writeFixture(t, filepath.Join(assets, "spotlight01"), 300*1024)
	// Ext-less but too small -> skipped.
	writeFixture(t, filepath.Join(assets, "thumb02"), 20*1024)

	count := extractFromProfile(profile, target)
	if count != 1 {
		t.Fatalf("count = %d, want 1", count)
	}
	if _, err := os.Stat(filepath.Join(target, "spotlight01.jpg")); err != nil {
		t.Errorf("ext-less asset should be copied with .jpg suffix: %v", err)
	}
	if _, err := os.Stat(filepath.Join(target, "thumb02.jpg")); err == nil {
		t.Error("small ext-less asset must be skipped")
	}
}

func TestExtractFromProfile_CachedFilesAndPictures(t *testing.T) {
	profile := t.TempDir()
	target := t.TempDir()
	writeFixture(t, filepath.Join(profile,
		"AppData", "Roaming", "Microsoft", "Windows", "Themes", "CachedFiles", "cached.jpg"), 100*1024)
	writeFixture(t, filepath.Join(profile, "Pictures", "Wallpapers", "mine.png"), 100*1024)

	count := extractFromProfile(profile, target)
	if count != 2 {
		t.Fatalf("count = %d, want 2 (CachedFiles + Pictures/Wallpapers)", count)
	}
	for _, name := range []string{"cached.jpg", "mine.png"} {
		if _, err := os.Stat(filepath.Join(target, name)); err != nil {
			t.Errorf("%s not copied: %v", name, err)
		}
	}
}

func TestExtractFromDir_DedupsSameNamedFiles(t *testing.T) {
	src := t.TempDir()
	target := t.TempDir()
	writeFixture(t, filepath.Join(src, "wall.jpg"), 100*1024)
	writeFixture(t, filepath.Join(src, "wall.jpg"), 100*1024) // overwrites, same name

	count := extractFromDir(src, target, 10)
	if count != 1 {
		t.Fatalf("count = %d, want 1", count)
	}
	if _, err := os.Stat(filepath.Join(target, "wall.jpg")); err != nil {
		t.Errorf("wall.jpg not copied: %v", err)
	}
}

func TestExtractFromDir_ExcludesNonImageAndOversized(t *testing.T) {
	src := t.TempDir()
	target := t.TempDir()
	writeFixture(t, filepath.Join(src, "a.png"), 100*1024)
	writeFixture(t, filepath.Join(src, "b.txt"), 100*1024)        // wrong extension
	writeFixture(t, filepath.Join(src, "huge.bmp"), 30*1024*1024) // >20MB cap

	count := extractFromDir(src, target, 10)
	if count != 1 {
		t.Fatalf("count = %d, want 1 (only a.png)", count)
	}
}

func TestExtractWallpapersFromPictures_Subdirs(t *testing.T) {
	pictures := t.TempDir()
	target := t.TempDir()
	writeFixture(t, filepath.Join(pictures, "Wallpapers", "w1.jpg"), 100*1024)
	writeFixture(t, filepath.Join(pictures, "backgrounds", "w2.jpg"), 100*1024)
	writeFixture(t, filepath.Join(pictures, "random", "w3.jpg"), 100*1024) // ignored

	count := extractWallpapersFromPictures(pictures, target)
	if count != 2 {
		t.Fatalf("count = %d, want 2", count)
	}
}

// --- ExtractWallpapers ---

func TestExtractWallpapers_FullFlow(t *testing.T) {
	scratch, mountPoint := withScratchDirs(t)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Alice",
		"AppData", "Roaming", "Microsoft", "Windows", "Themes", "TranscodedWallpaper"), 200*1024)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Alice", "Pictures", "Wallpapers", "mine.jpg"), 100*1024)
	writeFixture(t, filepath.Join(mountPoint, "Windows", "Web", "Wallpaper", "sys.jpg"), 100*1024)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Public", "shared.jpg"), 100*1024) // skipped

	fakeRun(t)
	result, err := sl(t).ExtractWallpapers("/dev/sda2")
	if err != nil {
		t.Fatalf("ExtractWallpapers: %v", err)
	}
	if !result.Found {
		t.Fatal("Found = false, want true")
	}
	// Alice: TranscodedWallpaper + Pictures/Wallpapers + system default = 3.
	if result.Count != 3 {
		t.Errorf("Count = %d, want 3", result.Count)
	}
	if result.TotalBytes <= 0 {
		t.Errorf("TotalBytes = %d, want > 0", result.TotalBytes)
	}
	if result.ScratchDir != filepath.Join(scratch, "wallpapers") {
		t.Errorf("ScratchDir = %q", result.ScratchDir)
	}
	for _, name := range []string{"TranscodedWallpaper", "mine.jpg", "sys.jpg"} {
		if _, err := os.Stat(filepath.Join(scratch, "wallpapers", "Alice", name)); err != nil {
			if name == "sys.jpg" {
				if _, err2 := os.Stat(filepath.Join(scratch, "wallpapers", "_windows_defaults", name)); err2 != nil {
					t.Errorf("%s not copied anywhere: %v", name, err2)
				}
				continue
			}
			t.Errorf("%s not copied: %v", name, err)
		}
	}
}

func TestExtractWallpapers_MountFailure(t *testing.T) {
	_, mountPoint := withScratchDirs(t)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Alice", "Documents", "a.txt"), 10)

	fakeRun(t, "mount")
	result, err := sl(t).ExtractWallpapers("/dev/sda2")
	if err == nil {
		t.Fatal("expected a mount error")
	}
	if result.Found {
		t.Error("Found must stay false when nothing was extracted")
	}
}

// --- CleanupScratch ---

func TestCleanupScratch(t *testing.T) {
	scratch, _ := withScratchDirs(t)
	writeFixture(t, filepath.Join(scratch, "wallpapers", "x.jpg"), 100)
	sl(t).CleanupScratch()
	if _, err := os.Stat(scratch); !os.IsNotExist(err) {
		t.Errorf("scratch dir should be gone after CleanupScratch, err=%v", err)
	}
}

// --- data.go: categoryPath / streamCategory ---

func TestCategoryPath(t *testing.T) {
	cases := map[string]string{
		"Documents":  "Documents",
		"documents":  "Documents", // case-insensitive
		"Pictures":   "Pictures",
		"Wallpapers": "AppData/Roaming/Microsoft/Windows/Themes",
		"Nonsense":   "",
	}
	for in, want := range cases {
		if got := CategoryPath(in); got != want {
			t.Errorf("CategoryPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestStreamCategory_CopiesAndCounts(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	writeFixture(t, filepath.Join(src, "a.txt"), 100)
	writeFixture(t, filepath.Join(src, "sub", "b.txt"), 50)
	writeFixture(t, filepath.Join(src, ".hidden"), 999)                   // skipped (dotfile)
	writeFixture(t, filepath.Join(src, "$Recycle.Bin", "$Rabc.jpg"), 999) // skipped ($-prefixed)

	bytes, count := streamCategory(src, dst, 10_000)
	if count != 2 {
		t.Errorf("count = %d, want 2", count)
	}
	if bytes != 150 {
		t.Errorf("bytes = %d, want 150", bytes)
	}
	for _, rel := range []string{"a.txt", filepath.Join("sub", "b.txt")} {
		if _, err := os.Stat(filepath.Join(dst, rel)); err != nil {
			t.Errorf("missing copied %s: %v", rel, err)
		}
	}
}

func TestStreamCategory_RespectsBudget(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	writeFixture(t, filepath.Join(src, "a.txt"), 100)
	writeFixture(t, filepath.Join(src, "big.bin"), 500) // pushes past budget

	bytes, count := streamCategory(src, dst, 150)
	if bytes > 150 {
		t.Errorf("bytes = %d, want <= 150 (budget)", bytes)
	}
	if count != 1 {
		t.Errorf("count = %d, want 1 (copy stops at the budget)", count)
	}
}

func TestStreamCategory_SkipsHugeFiles(t *testing.T) {
	src := t.TempDir()
	dst := t.TempDir()
	writeFixture(t, filepath.Join(src, "ok.txt"), 10)
	// Sparse 501MB file: skipped by the >500MB check before any read.
	huge := filepath.Join(src, "huge.bin")
	f, err := os.OpenFile(huge, os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(501 * 1024 * 1024); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}

	bytes, count := streamCategory(src, dst, 1<<30)
	if count != 1 || bytes != 10 {
		t.Errorf("count=%d bytes=%d, want 1/10 (huge file skipped)", count, bytes)
	}
}

// --- ExtractData / InjectData ---

func TestExtractData_FullFlow(t *testing.T) {
	scratch, mountPoint := withScratchDirs(t)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Alice", "Documents", "a.txt"), 100)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Alice", "Pictures", "p.png"), 200)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Bob", "Documents", "b.txt"), 50)

	fakeRun(t)
	// 1 MiB above the reserve: a deterministic budget, independent of the
	// host's /run, that comfortably fits the 300-byte fixture.
	fakeScratchCapacity(t, ScratchReserve+1<<20, nil)
	config := &SlurpConfig{
		SourcePartition: "/dev/sda2",
		Users: []SlurpUserConfig{
			{Name: "Alice", Categories: []string{"Documents", "Pictures", "Missing"}},
			{Name: "Carol", Categories: []string{"Documents"}}, // profile absent -> skipped
		},
	}
	result, err := sl(t).ExtractData(config)
	if err != nil {
		t.Fatalf("ExtractData: %v", err)
	}
	if !result.Found {
		t.Fatal("Found = false, want true")
	}
	if result.TotalBytes != 300 || result.FileCount != 2 {
		t.Errorf("TotalBytes=%d FileCount=%d, want 300/2", result.TotalBytes, result.FileCount)
	}
	if len(result.Users) != 1 || result.Users[0].Name != "Alice" {
		t.Fatalf("users = %+v, want only Alice", result.Users)
	}
	if len(result.Users[0].Categories) != 2 {
		t.Errorf("Alice categories = %+v, want Documents + Pictures", result.Users[0].Categories)
	}
	if _, err := os.Stat(filepath.Join(scratch, "data", "Alice", "Documents", "a.txt")); err != nil {
		t.Errorf("data not copied to scratch: %v", err)
	}
}

// checkExtractDataWithoutBudget runs ExtractData when the /run capacity
// observation yields no usable budget and checks that nothing was copied,
// nothing is claimed as migrated, and the Windows partition is still
// unmounted.
func checkExtractDataWithoutBudget(t *testing.T, available int64, statErr error) {
	t.Helper()
	scratch, mountPoint := withScratchDirs(t)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Alice", "Documents", "a.txt"), 100)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Alice", "Pictures", "p.png"), 200)

	calls := fakeRun(t)
	observed := fakeScratchCapacity(t, available, statErr)
	result, err := sl(t).ExtractData(&SlurpConfig{
		SourcePartition: "/dev/sda2",
		Users:           []SlurpUserConfig{{Name: "Alice", Categories: []string{"Documents", "Pictures"}}},
	})
	if err != nil {
		t.Fatalf("ExtractData: %v", err)
	}
	if got := observed(); len(got) != 1 || got[0] != "/run" {
		t.Errorf("scratch capacity observations = %v, want exactly one of /run", got)
	}
	if result.Found {
		t.Error("Found = true without a scratch budget; nothing may be reported as migrated")
	}
	if result.TotalBytes != 0 || result.FileCount != 0 {
		t.Errorf("TotalBytes=%d FileCount=%d, want 0/0", result.TotalBytes, result.FileCount)
	}
	for _, u := range result.Users {
		for _, c := range u.Categories {
			if c.Bytes != 0 || c.Count != 0 {
				t.Errorf("%s/%s reports %d bytes in %d files, want none", u.Name, c.Name, c.Bytes, c.Count)
			}
		}
	}
	var copied []string
	_ = filepath.Walk(filepath.Join(scratch, "data"), func(path string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() {
			copied = append(copied, path)
		}
		return nil
	})
	if len(copied) != 0 {
		t.Errorf("files copied to scratch without a budget: %v", copied)
	}
	want := strings.Join([]string{
		"mount -t ntfs3 -o ro,noatime /dev/sda2 " + mountPoint,
		"umount " + mountPoint,
	}, "\n")
	if got := strings.Join(calls(), "\n"); got != want {
		t.Errorf("runner calls:\n%s\nwant mount then umount:\n%s", got, want)
	}
}

func TestExtractData_ZeroScratchBudget(t *testing.T) {
	// /run has exactly the reserve free: the budget is zero.
	checkExtractDataWithoutBudget(t, ScratchReserve, nil)
}

func TestExtractData_ScratchCapacityObservationFails(t *testing.T) {
	checkExtractDataWithoutBudget(t, ScratchReserve+1<<30, syscall.EIO)
}

func TestAvailableScratchBytes_KeepsReserve(t *testing.T) {
	cases := []struct {
		name      string
		available int64
		err       error
		want      int64
	}{
		{"observation fails", ScratchReserve + 1<<30, syscall.EIO, 0},
		{"below reserve", ScratchReserve - 1, nil, 0},
		{"exactly reserve", ScratchReserve, nil, 0},
		{"above reserve", ScratchReserve + 1<<20, nil, 1 << 20},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			observed := fakeScratchCapacity(t, c.available, c.err)
			if got := sl(t).AvailableScratchBytes(); got != c.want {
				t.Errorf("sl(t).AvailableScratchBytes() = %d, want %d", got, c.want)
			}
			if got := observed(); len(got) != 1 || got[0] != "/run" {
				t.Errorf("observed %v, want /run", got)
			}
		})
	}
}

func TestExtractData_InvalidConfig(t *testing.T) {
	if _, err := sl(t).ExtractData(nil); err == nil {
		t.Error("nil config must error")
	}
	if _, err := sl(t).ExtractData(&SlurpConfig{SourcePartition: "/dev/sda2"}); err == nil {
		t.Error("config without users must error")
	}
}

func TestExtractData_MountFailure(t *testing.T) {
	_, mountPoint := withScratchDirs(t)
	writeFixture(t, filepath.Join(mountPoint, "Users", "Alice", "Documents", "a.txt"), 10)

	fakeRun(t, "mount")
	_, err := sl(t).ExtractData(&SlurpConfig{
		SourcePartition: "/dev/sda2",
		Users:           []SlurpUserConfig{{Name: "Alice", Categories: []string{"Documents"}}},
	})
	if err == nil {
		t.Fatal("expected a mount error")
	}
}

func TestInjectData_Success(t *testing.T) {
	target := t.TempDir()
	scratch := t.TempDir()
	writeFixture(t, filepath.Join(scratch, "Alice", "Documents", "a.txt"), 100)
	varDir := filepath.Join(target, "ostree", "deploy", "default", "var")
	if err := os.MkdirAll(filepath.Join(varDir, "home", "bob"), 0o755); err != nil {
		t.Fatal(err)
	}

	calls := fakeRun(t)
	result := &DataSlurpResult{
		Found:      true,
		ScratchDir: scratch,
		TotalBytes: 100,
		Users: []SlurpUserResult{{
			Name:       "Alice",
			Categories: []SlurpCategoryResult{{Name: "Documents", Bytes: 100, Count: 1}},
		}},
	}
	if err := sl(t).InjectData(varDir, result); err != nil {
		t.Fatalf("InjectData: %v", err)
	}
	// First non-hidden dir under var/home (bob) becomes the user home.
	dst := filepath.Join(varDir, "home", "bob", "Documents")
	if _, err := os.Stat(dst); err != nil {
		t.Errorf("Documents dir not created under first user home: %v", err)
	}
	joined := strings.Join(calls(), " ")
	if !strings.Contains(joined, "cp -a "+scratch+"/Alice/Documents/."+" "+dst+"/") {
		t.Errorf("expected cp -a into the user home, calls: %s", joined)
	}
	if !strings.Contains(joined, "chown -R 1000:1000") {
		t.Errorf("expected chown of the user home, calls: %s", joined)
	}
}

func TestInjectData_ComposefsNativePath(t *testing.T) {
	target := t.TempDir()
	scratch := t.TempDir()
	writeFixture(t, filepath.Join(scratch, "Alice", "Documents", "a.txt"), 100)

	fakeRun(t)
	result := &DataSlurpResult{
		Found:      true,
		ScratchDir: scratch,
		Users: []SlurpUserResult{{
			Name:       "Alice",
			Categories: []SlurpCategoryResult{{Name: "Documents"}},
		}},
	}
	if err := sl(t).InjectData(filepath.Join(target, "state", "os", "default", "var"), result); err != nil {
		t.Fatalf("InjectData: %v", err)
	}
	home := filepath.Join(target, "state", "os", "default", "var", "home")
	if _, err := os.Stat(filepath.Join(home, "Documents")); err != nil {
		t.Errorf("composefs-native home path not used: %v", err)
	}
}

// The wallpapers go to the /var it is handed, root-owned, and nothing lands
// beside it. (fisherman's own adapter test pins which /var that is on the
// ostree and composefs layouts: tuna-os/fisherman#407.)
func TestInjectWallpapers_GoesToTheGivenVar(t *testing.T) {
	target := t.TempDir()
	varDir := filepath.Join(target, "ostree", "deploy", "default", "var")
	scratch := t.TempDir()
	writeFixture(t, filepath.Join(scratch, "x.jpg"), 100)

	calls := fakeRun(t)
	result := &WallpaperResult{Found: true, ScratchDir: scratch, Count: 1, TotalBytes: 100}
	if err := sl(t).InjectWallpapers(varDir, result); err != nil {
		t.Fatalf("InjectWallpapers: %v", err)
	}
	bgDir := filepath.Join(varDir, "home", ".windows-wallpapers")
	if _, err := os.Stat(bgDir); err != nil {
		t.Errorf("wallpaper dir not created in the given /var: %v", err)
	}
	if _, err := os.Stat(filepath.Join(target, "var")); !os.IsNotExist(err) {
		t.Errorf("wrote into <target>/var: %v", err)
	}
	joined := strings.Join(calls(), " ")
	if !strings.Contains(joined, "cp -a "+scratch+"/. "+bgDir+"/") {
		t.Errorf("expected cp -a from scratch into bgDir, calls: %s", joined)
	}
	// A shared directory belongs to root; uid 1000 is nobody yet.
	if strings.Contains(joined, "1000:1000") {
		t.Errorf("wallpapers given to a hardcoded uid: %s", joined)
	}
	if !strings.Contains(joined, "chown -R 0:0 "+bgDir) {
		t.Errorf("expected root ownership of the wallpaper dir, calls: %s", joined)
	}
}

func TestInjectData_NilOrNotFound(t *testing.T) {
	if err := sl(t).InjectData("/tmp/t", nil); err != nil {
		t.Errorf("nil result: %v", err)
	}
	if err := sl(t).InjectData("/tmp/t", &DataSlurpResult{Found: false}); err != nil {
		t.Errorf("not-found result: %v", err)
	}
}
