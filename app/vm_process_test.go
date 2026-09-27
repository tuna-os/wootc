package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

type noopVMJob struct{}

func (noopVMJob) Close() error { return nil }

// A real child process exercises inherited handles, QMP negotiation, observed
// shutdown, and actual process reaping rather than mocking a completion flag.
func TestVMQMPChild(t *testing.T) {
	mode := os.Getenv("WOOTC_TEST_QMP_CHILD")
	if mode == "" {
		return
	}
	fmt.Println(`{"QMP":{"version":{},"capabilities":[]}}`)
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var request map[string]string
		if json.Unmarshal(scanner.Bytes(), &request) != nil {
			os.Exit(8)
		}
		fmt.Printf("{\"return\":{},\"id\":%q}\n", request["id"])
		if request["execute"] == "system_powerdown" {
			switch mode {
			case "clean":
				fmt.Println(`{"event":"SHUTDOWN","data":{"guest":true,"reason":"guest-shutdown"}}`)
				os.Exit(0)
			case "host":
				fmt.Println(`{"event":"SHUTDOWN","data":{"guest":false,"reason":"host-qmp-quit"}}`)
				os.Exit(0)
			case "crash":
				os.Exit(9)
			case "hung": // A responsive QMP endpoint is not proof of guest shutdown.
			}
		}
	}
	os.Exit(7)
}

func TestManagedVMShutdownContract(t *testing.T) {
	for _, mode := range []string{"clean", "host", "crash", "hung"} {
		t.Run(mode, func(t *testing.T) {
			root := t.TempDir()
			disk := filepath.Join(root, "root.disk")
			if err := os.WriteFile(disk, []byte("persistent user data"), 0600); err != nil {
				t.Fatal(err)
			}
			lease, err := acquireVMLock(disk)
			if err != nil {
				t.Fatal(err)
			}
			released := make(chan struct{})
			cmd := exec.Command(os.Args[0], "-test.run=^TestVMQMPChild$")
			cmd.Env = append(os.Environ(), "WOOTC_TEST_QMP_CHILD="+mode)
			statePath := filepath.Join(root, "state.json")
			state := VMState{InstallID: "install-123", DiskPath: disk, Phase: vmReady}
			session, err := startManagedVM(cmd, statePath, state, func() { lease(); close(released) }, func(*exec.Cmd) (io.Closer, error) { return noopVMJob{}, nil })
			if err != nil {
				lease()
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = session.force() })
			if _, err := acquireVMLock(disk); err == nil {
				t.Fatal("running image accepted a second writer")
			}
			if session.snapshot().DesktopReady {
				t.Fatal("QMP liveness became desktop readiness")
			}
			timeout := 5 * time.Second
			if mode == "hung" {
				timeout = 150 * time.Millisecond
			}
			ctx, cancel := context.WithTimeout(context.Background(), timeout)
			defer cancel()
			err = session.stop(ctx)
			if mode == "clean" && err != nil {
				t.Fatal(err)
			}
			if mode != "clean" && err == nil {
				t.Fatal("unverified shutdown accepted")
			}
			if mode == "hung" {
				select {
				case <-released:
					t.Fatal("timed-out guest lost writer protection")
				default:
				}
				if _, err := acquireVMLock(disk); err == nil {
					t.Fatal("hung guest accepted a writer")
				}
				if err := session.force(); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case <-session.done:
			case <-time.After(5 * time.Second):
				t.Fatal("child not reaped")
			}
			got, err := readVMState(statePath)
			if err != nil {
				t.Fatal(err)
			}
			want := vmRecovery
			if mode == "clean" {
				want = vmStopped
			}
			if got.Phase != want || got.PID != 0 || got.DesktopReady {
				t.Fatalf("state = %+v", got)
			}
			next, err := acquireVMLock(disk)
			if err != nil {
				t.Fatal(err)
			}
			next()
			data, err := os.ReadFile(disk)
			if err != nil || string(data) != "persistent user data" {
				t.Fatalf("disk changed: %q %v", data, err)
			}
		})
	}
}
