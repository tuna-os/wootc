//go:build windows

package main

import (
	"os"
	"syscall"

	"golang.org/x/sys/windows"
)

// attachParentConsole enables terminal output for GUI-subsystem CLI commands.
// AttachConsole can replace inherited standard handles. Preserve redirected
// pipes/files first, so status output and errors still reach their caller.
func attachParentConsole() {
	streams := []struct {
		id    uint32
		name  string
		file  **os.File
		saved windows.Handle
	}{
		{windows.STD_OUTPUT_HANDLE, "/dev/stdout", &os.Stdout, 0},
		{windows.STD_ERROR_HANDLE, "/dev/stderr", &os.Stderr, 0},
		{windows.STD_INPUT_HANDLE, "/dev/stdin", &os.Stdin, 0},
	}
	defer func() {
		for _, s := range streams {
			if s.saved != 0 {
				windows.CloseHandle(s.saved)
			}
		}
	}()
	for i := range streams {
		s := &streams[i]
		h, err := windows.GetStdHandle(s.id)
		if err != nil || h == 0 || h == windows.InvalidHandle {
			continue
		}
		kind, err := windows.GetFileType(h)
		if err != nil || (kind != windows.FILE_TYPE_PIPE && kind != windows.FILE_TYPE_DISK) {
			continue
		}
		// Duplicate before attachment in case Windows replaces or closes a handle.
		process := windows.CurrentProcess()
		if windows.DuplicateHandle(process, h, process, &s.saved, 0, true, windows.DUPLICATE_SAME_ACCESS) != nil {
			return
		}
	}
	attach := syscall.NewLazyDLL("kernel32.dll").NewProc("AttachConsole")
	const attachParentProcess = ^uintptr(0)
	if result, _, _ := attach.Call(attachParentProcess); result == 0 {
		return
	}
	for i := range streams {
		s := &streams[i]
		if s.saved != 0 {
			// os.File owns the duplicate after this point, including if restoring the
			// process handle table fails; Go output must retain the inherited stream.
			_ = windows.SetStdHandle(s.id, s.saved)
			*s.file = os.NewFile(uintptr(s.saved), s.name)
			s.saved = 0
			continue
		}
		h, err := windows.GetStdHandle(s.id)
		if err == nil && h != 0 && h != windows.InvalidHandle {
			*s.file = os.NewFile(uintptr(h), s.name)
		}
	}
}
