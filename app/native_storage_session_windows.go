//go:build windows

package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf16"
	"unsafe"
)

// PROC_THREAD_ATTRIBUTE_JOB_LIST: input attribute 13, available since Windows 10.
// https://learn.microsoft.com/windows/win32/api/processthreadsapi/nf-processthreadsapi-updateprocthreadattribute
const nativeProcThreadAttributeJobList = 0x0002000D

// JOB_LIST assigns ownership before code runs. HANDLE_LIST permits only the
// three explicit pipes. No helper process survives a failed or canceled read.
type nativeStorageSession struct {
	ctx                                                         context.Context
	job, process                                                windows.Handle
	pid                                                         uint32
	input, output                                               *os.File
	reader                                                      *bufio.Reader
	stderr                                                      boundedNativeOutput
	stderrDone, cancelDone, cancelStopped                       chan struct{}
	stderrRead                                                  *os.File
	stderrErr                                                   error
	streamsJoined, streamsComplete, forcedCleanup, exitObserved bool
	nonce                                                       string
	sequence                                                    int
	started                                                     time.Time
	auditMilliseconds                                           int64
	once                                                        sync.Once
	closeErr                                                    error
	exited, drained                                             bool
	exitCode                                                    uint32
}

func startNativeStorageSession(ctx context.Context) (*nativeStorageSession, error) {
	command, audit, err := prepareNativeStorageCommand(ctx)
	if err != nil {
		return nil, err
	}
	var random [16]byte
	if _, err = rand.Read(random[:]); err != nil {
		return nil, fmt.Errorf("storage session unavailable")
	}
	s := &nativeStorageSession{ctx: ctx, nonce: hex.EncodeToString(random[:]), auditMilliseconds: audit, started: time.Now(), stderrDone: make(chan struct{}), cancelDone: make(chan struct{}), cancelStopped: make(chan struct{})}
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, fmt.Errorf("storage session unavailable")
	}
	s.job = job
	success := false
	defer func() {
		if !success {
			windows.CloseHandle(job)
		}
	}()
	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err = windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&limits)), uint32(unsafe.Sizeof(limits))); err != nil {
		return nil, fmt.Errorf("storage session unavailable")
	}
	inputRead, inputWrite, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	defer inputRead.Close()
	outputRead, outputWrite, err := os.Pipe()
	if err != nil {
		inputWrite.Close()
		return nil, err
	}
	defer outputWrite.Close()
	errorRead, errorWrite, err := os.Pipe()
	if err != nil {
		inputWrite.Close()
		outputRead.Close()
		return nil, err
	}
	defer errorWrite.Close()
	defer func() {
		if !success {
			inputWrite.Close()
			outputRead.Close()
			errorRead.Close()
		}
	}()
	handles := []windows.Handle{windows.Handle(inputRead.Fd()), windows.Handle(outputWrite.Fd()), windows.Handle(errorWrite.Fd())}
	for _, handle := range handles {
		if err = windows.SetHandleInformation(handle, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT); err != nil {
			return nil, err
		}
	}
	attrs, err := windows.NewProcThreadAttributeList(2)
	if err != nil {
		return nil, err
	}
	defer attrs.Delete()
	if err = attrs.Update(windows.PROC_THREAD_ATTRIBUTE_HANDLE_LIST, unsafe.Pointer(&handles[0]), uintptr(len(handles))*unsafe.Sizeof(handles[0])); err != nil {
		return nil, err
	}
	jobs := []windows.Handle{job}
	if err = attrs.Update(nativeProcThreadAttributeJobList, unsafe.Pointer(&jobs[0]), unsafe.Sizeof(job)); err != nil {
		return nil, err
	}
	startup := windows.StartupInfoEx{}
	startup.Cb = uint32(unsafe.Sizeof(startup))
	startup.Flags = windows.STARTF_USESTDHANDLES
	startup.StdInput = handles[0]
	startup.StdOutput = handles[1]
	startup.StdErr = handles[2]
	startup.ProcThreadAttributeList = attrs.List()
	var process windows.ProcessInformation
	executable, err := windows.UTF16PtrFromString(command.Path)
	if err != nil {
		return nil, err
	}
	args := make([]string, len(command.Args))
	for i, arg := range command.Args {
		args[i] = windows.EscapeArg(arg)
	}
	line, err := windows.UTF16PtrFromString(strings.Join(args, " "))
	if err != nil {
		return nil, err
	}
	directory, err := windows.UTF16PtrFromString(command.Dir)
	if err != nil {
		return nil, err
	}
	environment := append(command.Env, "WOOTC_NATIVE_STORAGE_SESSION="+s.nonce)
	sort.Slice(environment, func(i, j int) bool { return strings.ToUpper(environment[i]) < strings.ToUpper(environment[j]) })
	block := utf16.Encode([]rune(strings.Join(environment, "\x00") + "\x00\x00"))
	if err = windows.CreateProcess(executable, line, nil, nil, true, windows.CREATE_UNICODE_ENVIRONMENT|windows.CREATE_NO_WINDOW|windows.EXTENDED_STARTUPINFO_PRESENT, &block[0], directory, &startup.StartupInfo, &process); err != nil {
		return nil, fmt.Errorf("storage session unavailable")
	}
	windows.CloseHandle(process.Thread)
	s.process = process.Process
	s.pid = process.ProcessId
	s.input = inputWrite
	s.output = outputRead
	s.reader = bufio.NewReaderSize(outputRead, 32768)
	s.stderrRead = errorRead
	success = true
	go func() {
		defer close(s.stderrDone)
		defer errorRead.Close()
		_, s.stderrErr = io.Copy(&s.stderr, errorRead)
	}()
	go func() {
		defer close(s.cancelStopped)
		select {
		case <-ctx.Done():
			// Unblock in-flight readers without destroying leftover
			// evidence: close() observes live owned processes and
			// force-reaps them with the termination recorded.
			s.input.Close()
			s.output.Close()
		case <-s.cancelDone:
		}
	}()
	return s, nil
}

func (s *nativeStorageSession) query(ctx context.Context) ([]nativeStorageRow, error) {
	if ctx.Err() != nil || s.sequence >= 2 {
		return nil, s.failure()
	}
	s.sequence++
	if _, err := fmt.Fprintf(s.input, "%s|%d\n", s.nonce, s.sequence); err != nil {
		return nil, s.failure()
	}
	line, err := s.reader.ReadSlice('\n')
	if err != nil || len(line) > 32768 {
		return nil, s.failure()
	}
	var frame struct {
		SchemaVersion int             `json:"schemaVersion"`
		Nonce         string          `json:"nonce"`
		Sequence      int             `json:"sequence"`
		PID           uint32          `json:"pid"`
		Rows          json.RawMessage `json:"rows"`
	}
	if decodeNativeMetadataObject(line, &frame, []string{"schemaVersion", "nonce", "sequence", "pid", "rows"}) != nil || frame.SchemaVersion != 1 || frame.Nonce != s.nonce || frame.Sequence != s.sequence || frame.PID != s.pid {
		return nil, s.failure()
	}
	rows, err := decodeNativeStorageRows(frame.Rows)
	if err != nil {
		return nil, s.failure()
	}
	if s.sequence == 2 {
		if _, extraErr := s.reader.ReadByte(); extraErr != io.EOF {
			return nil, s.failure()
		}
		if err = s.close(false); err != nil {
			return nil, s.failure()
		}
	}
	if ctx.Err() != nil {
		return nil, s.failure()
	}
	return rows, nil
}

func (s *nativeStorageSession) close(abort bool) error {
	s.once.Do(func() {
		s.input.Close()
		// No up-front termination: the drain loop below observes live
		// leftovers first and records forced cleanup before reaping.
		// A hung parent is still bounded by the wait below.
		// Reaping observes cleanup only; it never extends configuration authority.
		wait, err := windows.WaitForSingleObject(s.process, 1000)
		if err != nil || wait != windows.WAIT_OBJECT_0 {
			windows.TerminateJobObject(s.job, 1)
			wait, err = windows.WaitForSingleObject(s.process, 1000)
		}
		s.exited = err == nil && wait == windows.WAIT_OBJECT_0
		if s.exited {
			err = windows.GetExitCodeProcess(s.process, &s.exitCode)
			s.exitObserved = err == nil
		}
		deadline := time.Now().Add(time.Second)
		terminatedLeftovers := false
		for {
			var counts struct {
				User, Kernel, PeriodUser, PeriodKernel int64
				Faults, Total, Active, Terminated      uint32
			}
			queryErr := windows.QueryInformationJobObject(s.job, windows.JobObjectBasicAccountingInformation, uintptr(unsafe.Pointer(&counts)), uint32(unsafe.Sizeof(counts)), nil)
			if queryErr == nil && counts.Active == 0 {
				s.drained = true
				break
			}
			if time.Now().After(deadline) {
				if !terminatedLeftovers {
					s.forcedCleanup = true
					windows.TerminateJobObject(s.job, 1)
					terminatedLeftovers = true
					deadline = time.Now().Add(time.Second)
				} else {
					break
				}
			}
			time.Sleep(10 * time.Millisecond)
		}
		close(s.cancelDone)
		<-s.cancelStopped
		s.output.Close()
		select {
		case <-s.stderrDone:
			s.streamsJoined = true
		case <-time.After(time.Second):
			s.forcedCleanup = true
			s.stderrRead.Close()
			select {
			case <-s.stderrDone:
				s.streamsJoined = true
			case <-time.After(time.Second):
			}
			err = fmt.Errorf("storage streams unavailable")
		}
		s.streamsComplete = s.streamsJoined && s.stderrErr == nil && !s.forcedCleanup
		if !s.exited || !s.drained || !s.streamsComplete || err != nil || (!abort && s.exitCode != 0) {
			s.closeErr = fmt.Errorf("storage helper termination refused")
		}
		windows.CloseHandle(s.process)
		windows.CloseHandle(s.job)
	})
	return s.closeErr
}

func (s *nativeStorageSession) failure() *nativeStorageObservationFailure {
	s.close(true)
	var raw []byte
	if s.streamsJoined {
		raw = append([]byte(nil), s.stderr.Bytes()...)
	}
	exit := -1
	if s.exitObserved {
		exit = int(s.exitCode)
	}
	return &nativeStorageObservationFailure{ExitCode: exit, PreparedParentExited: s.exited, PreparedJobDrained: s.drained, PreparedStreamsDrained: s.streamsComplete, PreparedForcedCleanup: s.forcedCleanup, Stderr: raw, Phase: nativeStoragePhase(raw), AuditStage: "complete", ContextState: nativeStorageContextState(s.ctx), CommandAttempted: true, CommandStarted: true, WaitCompleted: s.exited, CommandPID: int(s.pid), DeadlineExceeded: s.ctx.Err() == context.DeadlineExceeded, AuditMilliseconds: s.auditMilliseconds, CommandMilliseconds: time.Since(s.started).Milliseconds()}
}
