//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"os/exec"
	"syscall"
	"unsafe"
)

type vmJob struct{ handle windows.Handle }

func (j *vmJob) Close() error { return windows.CloseHandle(j.handle) }
func ownVMProcess(cmd *exec.Cmd) (io.Closer, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
	if err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	defer windows.CloseHandle(process)
	if err = windows.AssignProcessToJobObject(job, process); err != nil {
		windows.CloseHandle(job)
		return nil, err
	}
	if cmd.SysProcAttr != nil && cmd.SysProcAttr.CreationFlags&windows.CREATE_SUSPENDED != 0 {
		if err := resumeVMPrimaryThread(uint32(cmd.Process.Pid)); err != nil {
			windows.CloseHandle(job)
			return nil, err
		}
	}
	return &vmJob{handle: job}, nil
}

// Suspend before the child can open a disk, assign ownership, then resume.
// A crash before assignment may leave an inert process, never an unowned writer.
func vmProcessAttributes() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{HideWindow: true, CreationFlags: windows.CREATE_SUSPENDED}
}
func resumeVMPrimaryThread(pid uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	for err = windows.Thread32First(snapshot, &entry); err == nil; err = windows.Thread32Next(snapshot, &entry) {
		if entry.OwnerProcessID != pid {
			continue
		}
		thread, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
		if err != nil {
			return err
		}
		previous, err := windows.ResumeThread(thread)
		windows.CloseHandle(thread)
		if err != nil {
			return err
		}
		if previous != 1 {
			return fmt.Errorf("unexpected VM thread suspension count: %d", previous)
		}
		return nil
	}
	return fmt.Errorf("could not find suspended VM primary thread: %w", err)
}
