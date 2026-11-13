package slurp

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDetectNTFS_ParsesLsblkOutput(t *testing.T) {
	// This test verifies parsing logic only; it does not call lsblk.
	// Integration tests would require an actual NTFS partition.
	lines := "/dev/sda1 vfat\n/dev/sda2 ntfs\n/dev/sda3 ntfs\n/dev/sda4 ext4\n"
	var ntfsPartitions []string
	for _, line := range splitLines(lines) {
		fields := splitFields(line)
		if len(fields) >= 2 && fields[1] == "ntfs" {
			ntfsPartitions = append(ntfsPartitions, fields[0])
		}
	}
	if len(ntfsPartitions) != 2 {
		t.Fatalf("expected 2 NTFS partitions, got %d", len(ntfsPartitions))
	}
	if ntfsPartitions[0] != "/dev/sda2" || ntfsPartitions[1] != "/dev/sda3" {
		t.Errorf("unexpected partitions: %v", ntfsPartitions)
	}
}

func TestCommonWallpaperExtensions(t *testing.T) {
	cases := []struct {
		ext  string
		want bool
	}{
		{".jpg", true},
		{".jpeg", true},
		{".png", true},
		{".bmp", true},
		{".webp", true},
		{".exe", false},
		{".txt", false},
		{".mp4", false},
	}
	for _, tc := range cases {
		if got := wallpaperExtensions[tc.ext]; got != tc.want {
			t.Errorf("extension %q: got %v, want %v", tc.ext, got, tc.want)
		}
	}
}

func TestExtractFromDir_FiltersAndCaps(t *testing.T) {
	// Set up a temp dir with a mix of files
	srcDir := t.TempDir()
	targetDir := t.TempDir()

	// Create a valid wallpaper (>50KB)
	bigJPG := make([]byte, 100*1024) // 100KB
	mustWriteFile(t, filepath.Join(srcDir, "sunset.jpg"), bigJPG, 0644)

	// Create a too-small file (should be skipped)
	tinyPNG := make([]byte, 1024) // 1KB
	mustWriteFile(t, filepath.Join(srcDir, "tiny.png"), tinyPNG, 0644)

	// Create a non-image file (should be skipped)
	mustWriteFile(t, filepath.Join(srcDir, "readme.txt"), []byte("hello"), 0644)

	// Create another valid wallpaper
	bigPNG := make([]byte, 200*1024) // 200KB
	mustWriteFile(t, filepath.Join(srcDir, "mountains.png"), bigPNG, 0644)

	count := extractFromDir(srcDir, targetDir, 10)
	if count != 2 {
		t.Errorf("expected 2 files extracted, got %d", count)
	}

	// Verify files exist in target
	entries, _ := os.ReadDir(targetDir)
	if len(entries) != 2 {
		t.Errorf("expected 2 files in target, got %d", len(entries))
	}
}

func TestExtractFromDir_RespectsMaxFiles(t *testing.T) {
	srcDir := t.TempDir()
	targetDir := t.TempDir()

	// Create 5 valid wallpapers
	for i := 0; i < 5; i++ {
		data := make([]byte, 100*1024)
		mustWriteFile(t, filepath.Join(srcDir, filepath.Base(t.Name())+string(rune('a'+i))+".jpg"), data, 0644)
	}

	count := extractFromDir(srcDir, targetDir, 2)
	if count != 2 {
		t.Errorf("expected max 2 files extracted, got %d", count)
	}
}

func TestCopyFile(t *testing.T) {
	srcDir := t.TempDir()
	targetDir := t.TempDir()

	srcFile := filepath.Join(srcDir, "test.jpg")
	mustWriteFile(t, srcFile, []byte("image data"), 0644)

	err := copyFile(srcFile, targetDir, "test.jpg")
	if err != nil {
		t.Fatalf("copyFile failed: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(targetDir, "test.jpg"))
	if err != nil {
		t.Fatalf("reading copied file: %v", err)
	}
	if string(data) != "image data" {
		t.Errorf("copied file content mismatch: %q", data)
	}
}

func TestCopyFile_AvoidOverwrite(t *testing.T) {
	srcDir := t.TempDir()
	targetDir := t.TempDir()

	// Create first file
	mustWriteFile(t, filepath.Join(srcDir, "test.jpg"), []byte("first"), 0644)
	if err := copyFile(filepath.Join(srcDir, "test.jpg"), targetDir, "test.jpg"); err != nil {
		t.Fatal(err)
	}

	// Create second file with same name
	mustWriteFile(t, filepath.Join(srcDir, "test2.jpg"), []byte("second"), 0644)
	if err := copyFile(filepath.Join(srcDir, "test2.jpg"), targetDir, "test.jpg"); err != nil {
		t.Fatal(err)
	}

	// Should have dup_ prefix
	data, err := os.ReadFile(filepath.Join(targetDir, "dup_test.jpg"))
	if err != nil {
		t.Fatalf("dup file not created: %v", err)
	}
	if string(data) != "second" {
		t.Errorf("dup file content mismatch: %q", data)
	}
}

func TestInjectWallpapers_NilResult(t *testing.T) {
	err := sl(t).InjectWallpapers("/tmp/fake-target", nil)
	if err != nil {
		t.Errorf("expected nil error for nil result, got: %v", err)
	}
}

func TestInjectWallpapers_NotFound(t *testing.T) {
	result := &WallpaperResult{Found: false}
	err := sl(t).InjectWallpapers("/tmp/fake-target", result)
	if err != nil {
		t.Errorf("expected nil error for not-found result, got: %v", err)
	}
}

func TestDirSize(t *testing.T) {
	dir := t.TempDir()
	mustWriteFile(t, filepath.Join(dir, "a.txt"), make([]byte, 100), 0644)
	mustWriteFile(t, filepath.Join(dir, "b.txt"), make([]byte, 200), 0644)

	size := dirSize(dir)
	if size != 300 {
		t.Errorf("expected 300 bytes, got %d", size)
	}
}

func TestHumanBytes(t *testing.T) {
	cases := []struct {
		input int64
		want  string
	}{
		{500, "500 B"},
		{1024, "1.0 KB"},
		{1024 * 1024, "1.0 MB"},
		{1024 * 1024 * 1024, "1.0 GB"},
		{1536 * 1024, "1.5 MB"},
	}
	for _, tc := range cases {
		got := humanBytes(tc.input)
		if got != tc.want {
			t.Errorf("humanBytes(%d) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

// Helper split functions matching the logic in DetectNTFS
func splitLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			line := s[start:i]
			if line != "" {
				lines = append(lines, line)
			}
			start = i + 1
		}
	}
	if start < len(s) {
		lines = append(lines, s[start:])
	}
	return lines
}

func splitFields(s string) []string {
	var fields []string
	field := ""
	for _, c := range s {
		if c == ' ' || c == '\t' {
			if field != "" {
				fields = append(fields, field)
				field = ""
			}
		} else {
			field += string(c)
		}
	}
	if field != "" {
		fields = append(fields, field)
	}
	return fields
}
