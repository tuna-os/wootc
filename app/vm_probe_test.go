package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestVMExecutionProbeChild(t *testing.T) {
	mode := os.Getenv("WOOTC_TEST_PROBE_CHILD")
	if mode == "" {
		return
	}
	switch mode {
	case "guest":
		_ = os.WriteFile(os.Getenv("WOOTC_TEST_PROBE_SERIAL"), []byte(vmProbeMarker), 0600)
	case "stdout":
		fmt.Println(vmProbeMarker)
	case "exit":
		os.Exit(0)
	}
	time.Sleep(time.Minute)
	os.Exit(0)
}
func TestVMExecutionProbeNeedsActualSerial(t *testing.T) {
	for _, mode := range []string{"guest", "stdout", "hung", "exit"} {
		t.Run(mode, func(t *testing.T) {
			serial := filepath.Join(t.TempDir(), "serial.log")
			cmd := exec.Command(os.Args[0], "-test.run=^TestVMExecutionProbeChild$")
			cmd.Env = append(os.Environ(), "WOOTC_TEST_PROBE_CHILD="+mode, "WOOTC_TEST_PROBE_SERIAL="+serial)
			var output bytes.Buffer
			cmd.Stdout = &output
			timeout := time.Second
			if mode == "guest" {
				timeout = 5 * time.Second
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			result := runVMExecutionProbe(ctx, cmd, serial, func(*exec.Cmd) (io.Closer, error) { return noopVMJob{}, nil })
			if mode == "stdout" && !strings.Contains(output.String(), vmProbeMarker) {
				t.Fatal("stdout-only fixture did not execute")
			}
			if (result.Status == "passed") != (mode == "guest") {
				t.Fatalf("mode %s: %+v", mode, result)
			}
			if (mode == "hung" || mode == "stdout") && result.Status != "timed_out" {
				t.Fatalf("silence mislabeled unsupported: %+v", result)
			}
		})
	}
}
func TestVMExecutionProbeRefusesStaleLog(t *testing.T) {
	serial := filepath.Join(t.TempDir(), "serial.log")
	os.WriteFile(serial, []byte(vmProbeMarker), 0600)
	result := runVMExecutionProbe(context.Background(), exec.Command("does-not-exist"), serial, func(*exec.Cmd) (io.Closer, error) { t.Fatal("started with stale log"); return nil, nil })
	if result.Status == "passed" {
		t.Fatal("stale guest result accepted")
	}
}
func TestVMProbeBootSectorReproducible(t *testing.T) {
	if len(vmProbeBootSector) != 512 || fmt.Sprintf("%x", sha256.Sum256(vmProbeBootSector)) != "f591bb62b9fce510dc7a4a096940ffbfc596d925739416559017cfb2a92e7195" {
		t.Fatal("probe binary changed; rebuild and verify source")
	}
}
