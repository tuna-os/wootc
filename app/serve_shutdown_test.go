package main

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func waitSignal(t *testing.T, signal <-chan struct{}, description string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(3 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

// The worker is really running and has an observable boot marker. Cancellation
// reaches a deliberately blocked disarm operation: a cancellation signal alone
// must never let Serve return while that marker still exists.
func TestServeShutdownWaitsForArmedWorkerCleanup(t *testing.T) {
	for _, mode := range []string{"eof", "shutdown"} {
		t.Run(mode, func(t *testing.T) {
			app := NewApp()
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			armed, cleaning, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
			var releaseOnce sync.Once
			allowCleanup := func() { releaseOnce.Do(func() { close(release) }) }
			t.Cleanup(allowCleanup)
			marker := filepath.Join(t.TempDir(), "bootsequence")
			var persisted string
			if err := app.startInstallWorker(cancel, func() {
				if err := os.WriteFile(marker, []byte("linux armed"), 0600); err != nil {
					t.Error(err)
				}
				close(armed)
				<-ctx.Done()
				// Even a cleared status flag is insufficient: the boot operation is not done.
				app.mutateStatus(func(s *InstallStatus) { s.Running = false })
				err := finishInstallPipeline(ctx, true, func() {
					close(cleaning)
					<-release
					if err := os.Remove(marker); err != nil {
						t.Error(err)
					}
				}, func(state, _, _ string) { persisted = state })
				if !errors.Is(err, context.Canceled) {
					t.Errorf("late cancellation: %v", err)
				}
			}); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { allowCleanup(); cancel(); <-app.installDone })
			waitSignal(t, armed, "boot arming")
			in, client := io.Pipe()
			t.Cleanup(func() { _ = client.Close(); _ = in.Close() })
			result := make(chan error, 1)
			go func() { result <- Serve(context.Background(), app, in, io.Discard) }()
			if mode == "eof" {
				_ = client.Close()
			} else {
				if _, err := io.WriteString(client, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Shutdown\"}\n"); err != nil {
					t.Fatal(err)
				}
			}
			waitSignal(t, cleaning, "disarm operation")
			select {
			case err := <-result:
				t.Fatalf("Serve exited before disarming: %v", err)
			case <-time.After(50 * time.Millisecond):
			}
			if _, err := os.Stat(marker); err != nil {
				t.Fatalf("fixture was not still armed: %v", err)
			}
			allowCleanup()
			select {
			case err := <-result:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("Serve did not finish after cleanup")
			}
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatalf("boot remains armed: %v", err)
			}
			if persisted != StateStaged {
				t.Fatalf("cancellation claimed success: %s", persisted)
			}
		})
	}
}

func TestStopInstallGraceDoesNotKillOrPermitAnotherInstall(t *testing.T) {
	app := NewApp()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	release, warning, stopped := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var once sync.Once
	finish := func() { once.Do(func() { close(release) }) }
	t.Cleanup(finish)
	if err := app.startInstallWorker(cancel, func() { <-ctx.Done(); <-release }); err != nil {
		t.Fatal(err)
	}
	go func() { app.stopInstall(time.Millisecond, func() { close(warning) }); close(stopped) }()
	waitSignal(t, warning, "slow-cleanup warning")
	select {
	case <-stopped:
		t.Fatal("grace timeout killed pending cleanup")
	default:
	}
	if err := app.startInstallWorker(func() {}, func() { t.Error("shutdown accepted new work") }); err == nil {
		t.Fatal("accepted work during shutdown")
	}
	finish()
	waitSignal(t, stopped, "worker completion")
}

type readingSignal struct {
	io.Reader
	ready chan struct{}
	once  sync.Once
}

func (r *readingSignal) Read(p []byte) (int, error) {
	r.once.Do(func() { close(r.ready) })
	return r.Reader.Read(p)
}

type writingSignal struct {
	io.WriteCloser
	entered chan struct{}
	once    sync.Once
}

func (w *writingSignal) Write(p []byte) (int, error) {
	w.once.Do(func() { close(w.entered) })
	return w.WriteCloser.Write(p)
}

func TestServeDisconnectUnblocksInFlightProgressWrite(t *testing.T) {
	app := NewApp()
	in, client := io.Pipe()
	outReader, outWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer in.Close()
	defer client.Close()
	defer outReader.Close()
	defer outWriter.Close()
	reader := &readingSignal{Reader: in, ready: make(chan struct{})}
	writer := &writingSignal{WriteCloser: outWriter, entered: make(chan struct{})}
	result := make(chan error, 1)
	go func() { result <- Serve(context.Background(), app, reader, writer) }()
	waitSignal(t, reader.ready, "serve transport setup")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cleaned := make(chan struct{})
	writeReturned := make(chan struct{})
	if err := app.startInstallWorker(cancel, func() {
		app.emit(ProgressEvent{Step: "armed", Message: strings.Repeat("x", 1024*1024)})
		close(writeReturned)
		<-ctx.Done()
		app.emit(ProgressEvent{Step: "disarmed"}) // future writes must also be inert
		close(cleaned)
	}); err != nil {
		t.Fatal(err)
	}
	waitSignal(t, writer.entered, "notification write")
	select {
	case <-writeReturned:
		t.Fatal("notification did not fill the OS pipe; test never blocked")
	case <-time.After(50 * time.Millisecond):
	}
	_ = client.Close()
	select {
	case err := <-result:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("orphaned output blocked cleanup")
	}
	waitSignal(t, cleaned, "cleanup after broken output")
}
