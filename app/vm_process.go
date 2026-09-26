package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"
)

type vmSession struct {
	mu        sync.Mutex
	state     VMState
	statePath string
	cmd       *exec.Cmd
	qmp       *qmpClient
	job       io.Closer
	done      chan struct{}
	release   func()
	forced    bool
	output    *os.File
}

func startManagedVM(cmd *exec.Cmd, statePath string, state VMState, release func(), own func(*exec.Cmd) (io.Closer, error)) (*vmSession, error) {
	session := &vmSession{state: state, statePath: statePath, cmd: cmd, release: release, done: make(chan struct{})}
	session.state.Phase = vmStarting
	session.state.PID = 0
	session.state.Error = ""
	if err := writeVMState(statePath, session.state); err != nil {
		return nil, err
	}
	childInput, input, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	output, childOutput, err := os.Pipe()
	if err != nil {
		childInput.Close()
		input.Close()
		return nil, err
	}
	cmd.Stdin = childInput
	cmd.Stdout = childOutput
	session.output = output
	if err = cmd.Start(); err != nil {
		childInput.Close()
		input.Close()
		output.Close()
		childOutput.Close()
		return nil, err
	}
	childInput.Close()
	childOutput.Close()
	session.job, err = own(cmd)
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		session.qmp, err = connectQMP(ctx, input, output)
		cancel()
	}
	if err != nil {
		input.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		output.Close()
		if session.job != nil {
			session.job.Close()
		}
		session.state.Phase = vmRecovery
		session.state.Error = err.Error()
		_ = writeVMState(statePath, session.state)
		return nil, fmt.Errorf("VM control initialization failed: %w", err)
	}
	session.state.Phase = vmRunning
	session.state.PID = cmd.Process.Pid
	if err = writeVMState(statePath, session.state); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		session.qmp.input.Close()
		output.Close()
		session.job.Close()
		return nil, err
	}
	go session.wait()
	return session, nil
}

func (s *vmSession) wait() {
	waitErr := s.cmd.Wait()
	_ = s.job.Close() // Close descendant handles before draining QMP EOF.
	// The parent closed its copy of the child's write handle immediately after
	// Start. Drain the actual EOF before deciding whether SHUTDOWN was observed.
	<-s.qmp.done
	_ = s.output.Close()
	_ = s.qmp.input.Close()
	s.mu.Lock()
	s.state.PID = 0
	s.state.DesktopReady = false
	if waitErr == nil && s.qmp.clean() && !s.forced {
		s.state.Phase = vmStopped
		s.state.Error = ""
	} else {
		s.state.Phase = vmRecovery
		s.state.Error = "The VM stopped without verified guest shutdown. Its disk is preserved; check it before reuse."
		if waitErr != nil {
			s.state.Error += " " + waitErr.Error()
		}
	}
	if err := writeVMState(s.statePath, s.state); err != nil {
		s.state.Phase = vmRecovery
		s.state.Error = fmt.Sprintf("could not record VM shutdown: %v", err)
	}
	s.mu.Unlock()
	s.release()
	close(s.done)
}

func (s *vmSession) snapshot() VMState { s.mu.Lock(); defer s.mu.Unlock(); return s.state }

func (s *vmSession) stop(ctx context.Context) error {
	select {
	case <-s.done:
		if state := s.snapshot(); state.Phase != vmStopped {
			return fmt.Errorf("%s", state.Error)
		}
		return nil
	default:
	}
	s.mu.Lock()
	if s.state.Phase == vmStopped || s.state.Phase == vmRecovery {
		state := s.state
		s.mu.Unlock()
		if state.Phase == vmStopped {
			return nil
		}
		return fmt.Errorf("%s", state.Error)
	}
	s.state.Phase = vmStopping
	err := writeVMState(s.statePath, s.state)
	s.mu.Unlock()
	if err != nil {
		return err
	}
	if err = s.qmp.command(ctx, "system_powerdown"); err != nil {
		return fmt.Errorf("request clean guest shutdown: %w", err)
	}
	select {
	case <-s.done:
		state := s.snapshot()
		if state.Phase != vmStopped {
			return fmt.Errorf("%s", state.Error)
		}
		return nil
	case <-ctx.Done():
		return fmt.Errorf("Linux has not completed shutdown; its disk remains locked: %w", ctx.Err())
	}
}

func (s *vmSession) force() error {
	select {
	case <-s.done:
		return nil
	default:
	}
	s.mu.Lock()
	s.forced = true
	s.mu.Unlock()
	err := s.cmd.Process.Kill()
	<-s.done
	return err
}
