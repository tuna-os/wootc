//go:build windows

package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func TestVMOwnedJobReapsChildOnClose(t *testing.T) {
	if os.Getenv("WOOTC_TEST_JOB_CHILD") == "1" {
		fmt.Println("child-running")
		time.Sleep(time.Minute)
		os.Exit(0)
	}
	cmd := exec.Command(os.Args[0], "-test.run=^TestVMOwnedJobReapsChildOnClose$")
	cmd.Env = append(os.Environ(), "WOOTC_TEST_JOB_CHILD=1")
	cmd.SysProcAttr = vmProcessAttributes()
	output, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	job, err := ownVMProcess(cmd)
	if err != nil {
		cmd.Process.Kill()
		cmd.Wait()
		t.Fatal(err)
	}
	reader := bufio.NewReader(output)
	if line, err := reader.ReadString('\n'); err != nil || strings.TrimSpace(line) != "child-running" {
		job.Close()
		cmd.Wait()
		t.Fatalf("child never became active: %q %v", line, err)
	}
	if err := job.Close(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	select {
	case <-exited: // Windows may report exit code zero for job termination.
	case <-time.After(5 * time.Second):
		t.Fatal("owned child survived engine job closure")
	}
}

func TestVMEnvironmentDoesNotInheritUserPluginPaths(t *testing.T) {
	t.Setenv("GTK_PATH", `C:\Users\attacker`)
	t.Setenv("QEMU_MODULE_DIR", `C:\Users\attacker`)
	t.Setenv("PATH", `C:\Users\attacker`)
	env := vmProcessEnvironment(`C:\wootc\qemu`, `C:\wootc\vm`)
	for _, value := range env {
		if strings.Contains(value, "attacker") {
			t.Fatalf("inherited user search override: %s", value)
		}
	}
}
