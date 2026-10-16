package main

import (
	"context"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func storageContract(fields string) []byte {
	return []byte(`{"schemaVersion":1,"protocol":"wootc-helper","protocolVersion":1,"targetSerial":"wootc-root","scratchSerial":"wootc-scratch",` + fields + `}`)
}

func TestVMStorageMinimumsCompatibility(t *testing.T) {
	for _, tc := range []struct {
		name, fields    string
		target, scratch uint64
	}{
		{"legacy", `"minimumDiskBytes":34359738368`, 32 << 30, 32 << 30},
		{"pair", `"minimumTargetDiskBytes":34359738368,"minimumScratchDiskBytes":17179869184`, 32 << 30, 16 << 30},
		{"pair-with-conservative-legacy", `"minimumDiskBytes":34359738368,"minimumTargetDiskBytes":34359738368,"minimumScratchDiskBytes":17179869184`, 32 << 30, 16 << 30},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mins, err := parseVMStorageMinimums(storageContract(tc.fields))
			if err != nil {
				t.Fatal(err)
			}
			if mins.Target != tc.target || mins.Scratch != tc.scratch {
				t.Fatalf("swapped or lost bounds: %+v", mins)
			}
			required, err := defaultVMStoragePlan().requiredFree(mins)
			if err != nil || required != 88<<30 {
				t.Fatalf("helper minimum silently changed unproven host profile: %d %v", required, err)
			}
		})
	}
}
func TestVMStorageMinimumsRejectMalformedContracts(t *testing.T) {
	for _, fields := range []string{
		`"other":1`, `"minimumDiskBytes":0`, `"minimumDiskBytes":null`, `"minimumDiskBytes":34359738368,"minimumTargetDiskBytes":null,"minimumScratchDiskBytes":null`,
		`"minimumTargetDiskBytes":34359738368`, `"minimumScratchDiskBytes":17179869184`,
		`"minimumTargetDiskBytes":34359738368,"minimumScratchDiskBytes":0`,
		`"minimumTargetDiskBytes":34359738368,"minimumScratchDiskBytes":null`,
		`"minimumDiskBytes":17179869184,"minimumTargetDiskBytes":34359738368,"minimumScratchDiskBytes":17179869184`,
		`"minimumDiskBytes":-1`, `"minimumDiskBytes":1.5`, `"minimumDiskBytes":18446744073709551616`,
		`"minimumDiskBytes":"34359738368"`, `"minimumDiskBytes":1,"minimumDiskBytes":34359738368`, `"minimumDiskBytes":1,"MINIMUMDISKBYTES":34359738368`,
		`"protocolVersion":2,"minimumDiskBytes":34359738368`,
	} {
		t.Run(fields, func(t *testing.T) {
			if _, err := parseVMStorageMinimums(storageContract(fields)); err == nil {
				t.Fatal("accepted invalid metadata")
			}
		})
	}
	for _, data := range [][]byte{[]byte(`[]`), []byte(`null`), []byte(`{`), append(storageContract(`"minimumDiskBytes":34359738368`), []byte(` {}`)...), []byte(strings.Repeat(" ", 65537)), []byte(strings.Replace(string(storageContract(`"minimumDiskBytes":34359738368`)), `"protocolVersion":1`, `"protocolVersion":2`, 1))} {
		if _, err := parseVMStorageMinimums(data); err == nil {
			t.Fatal("accepted unsupported protocol")
		}
	}
}
func TestVMStorageAdmissionBoundaries(t *testing.T) {
	candidate := vmStoragePlan{Target: 32 << 30, Scratch: 16 << 30, Reserve: 8 << 30}
	mins := vmStorageMinimums{Target: 32 << 30, Scratch: 16 << 30}
	for _, plan := range []vmStoragePlan{defaultVMStoragePlan(), candidate} {
		required, err := plan.requiredFree(mins)
		if err != nil {
			t.Fatal(err)
		}
		if err := plan.admit(mins, required); err != nil {
			t.Fatal(err)
		}
		if err := plan.admit(mins, required-1); err == nil {
			t.Fatal("one-byte shortfall accepted")
		}
	}
	if required, _ := candidate.requiredFree(mins); required != 56<<30 {
		t.Fatal(required)
	}
	if err := candidate.admit(vmStorageMinimums{32 << 30, 32 << 30}, math.MaxUint64); err == nil {
		t.Fatal("candidate bypassed legacy scratch minimum")
	}
	for _, plan := range []vmStoragePlan{
		{31 << 30, 16 << 30, 8 << 30}, {32 << 30, (16 << 30) - 1, 8 << 30}, {32 << 30, 16 << 30, (8 << 30) - 1},
		{math.MaxUint64, 16 << 30, 8 << 30}, {math.MaxInt64, math.MaxInt64, 8 << 30},
	} {
		if err := plan.admit(mins, math.MaxUint64); err == nil {
			t.Fatal(fmt.Sprintf("invalid profile accepted: %+v", plan))
		}
	}
}

func TestVMCapacityWriterChild(t *testing.T) {
	path := os.Getenv("WOOTC_TEST_CAPACITY_WRITER")
	if path == "" {
		return
	}
	file, err := os.Create(path)
	if err != nil {
		os.Exit(21)
	}
	defer file.Close()
	for {
		if _, err := file.Write(make([]byte, 1024)); err != nil {
			os.Exit(22)
		}
		if err := file.Sync(); err != nil {
			os.Exit(23)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestVMCapacityDropCancelsActualWriterBeforeLeaseRelease(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "writer.disk")
	release, err := acquireVMLock(path)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	parent, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ctx, stop := guardVMFreeSpace(parent, 100, time.Millisecond, func() (uint64, error) {
		info, err := os.Stat(path)
		if os.IsNotExist(err) {
			return 200, nil
		}
		if err != nil {
			return 0, err
		}
		if info.Size() >= 4096 {
			return 99, nil
		}
		return 200, nil
	})
	defer stop()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestVMCapacityWriterChild$")
	cmd.Env = append(os.Environ(), "WOOTC_TEST_CAPACITY_WRITER="+path)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	<-ctx.Done()
	if releaseOther, err := acquireVMLock(path); err == nil {
		releaseOther()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		t.Fatal("writer lease released before process reap")
	}
	_ = cmd.Wait()
	if !strings.Contains(context.Cause(ctx).Error(), "reserve") {
		t.Fatal(context.Cause(ctx))
	}
	info, err := os.Stat(path)
	if err != nil || info.Size() < 4096 {
		t.Fatalf("test did not observe actual writes: %v", err)
	}
	if cmd.ProcessState == nil {
		t.Fatal("child not reaped")
	}
	release()
	reacquired, err := acquireVMLock(path)
	if err != nil {
		t.Fatalf("lease retained after reap: %v", err)
	}
	reacquired()
}
