//go:build windows

package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"

	"golang.org/x/sys/windows"
)

func TestConsoleRedirectChild(t *testing.T) {
	if os.Getenv("WOOTC_TEST_CONSOLE_CHILD") != "1" {
		t.Skip("subprocess only")
	}
	// Reproduce a GUI-subsystem child: detached from its console, with explicit
	// inherited pipes. Duplicates survive FreeConsole on all supported Windows.
	for _, stream := range []struct {
		id   uint32
		file **os.File
	}{{windows.STD_OUTPUT_HANDLE, &os.Stdout}, {windows.STD_ERROR_HANDLE, &os.Stderr}} {
		var h windows.Handle
		p := windows.CurrentProcess()
		if err := windows.DuplicateHandle(p, windows.Handle((*stream.file).Fd()), p, &h, 0, true, windows.DUPLICATE_SAME_ACCESS); err != nil {
			t.Fatal(err)
		}
		*stream.file = os.NewFile(uintptr(h), "redirected")
	}
	syscall.NewLazyDLL("kernel32.dll").NewProc("FreeConsole").Call()
	windows.SetStdHandle(windows.STD_OUTPUT_HANDLE, windows.Handle(os.Stdout.Fd()))
	windows.SetStdHandle(windows.STD_ERROR_HANDLE, windows.Handle(os.Stderr.Fd()))
	attachParentConsole()
	os.Stdout.WriteString("console-stdout-proof\n")
	os.Stderr.WriteString("console-stderr-proof\n")
	os.Exit(7)
}

func TestAttachParentConsolePreservesRedirectedOutput(t *testing.T) {
	for _, useFiles := range []bool{false, true} {
		t.Run(map[bool]string{false: "pipes", true: "files"}[useFiles], func(t *testing.T) {
			exe, err := os.Executable()
			if err != nil {
				t.Fatal(err)
			}
			dir := t.TempDir()
			script := filepath.Join(dir, "console-child.cmd")
			body := "@echo off\r\n\"" + exe + "\" -test.run=^TestConsoleRedirectChild$\r\nexit /b %errorlevel%\r\n"
			if err = os.WriteFile(script, []byte(body), 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("cmd.exe", "/d", "/c", script)
			cmd.Env = append(os.Environ(), "WOOTC_TEST_CONSOLE_CHILD=1")
			var stdout, stderr bytes.Buffer
			cmd.Stdout = &stdout
			cmd.Stderr = &stderr
			var outFile, errFile *os.File
			if useFiles {
				outFile, err = os.Create(filepath.Join(dir, "stdout"))
				if err != nil {
					t.Fatal(err)
				}
				defer outFile.Close()
				errFile, err = os.Create(filepath.Join(dir, "stderr"))
				if err != nil {
					t.Fatal(err)
				}
				defer errFile.Close()
				cmd.Stdout = outFile
				cmd.Stderr = errFile
			}
			err = cmd.Run()
			if useFiles {
				outFile.Close()
				errFile.Close()
				out, _ := os.ReadFile(outFile.Name())
				errOut, _ := os.ReadFile(errFile.Name())
				stdout.Write(out)
				stderr.Write(errOut)
			}
			if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 7 {
				t.Fatalf("exit=%v stdout=%s stderr=%s", err, &stdout, &stderr)
			}
			if !bytes.Contains(stdout.Bytes(), []byte("console-stdout-proof")) {
				t.Fatalf("stdout lost: %q", stdout.String())
			}
			if !bytes.Contains(stderr.Bytes(), []byte("console-stderr-proof")) {
				t.Fatalf("stderr lost: %q", stderr.String())
			}
		})
	}
}
