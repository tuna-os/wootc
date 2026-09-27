//go:build windows

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/sys/windows"
)

func runNativeServe(args []string) int {
	flags := flag.NewFlagSet("native-serve", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	var session string
	var sourcePID uint
	flags.StringVar(&session, "session", "", "native session")
	flags.UintVar(&sourcePID, "source-pid", 0, "retained source process")
	if len(args) < 2 || flags.Parse(args[2:]) != nil || len(flags.Args()) != 0 ||
		!lowerHexLength(session, 32) || sourcePID == 0 || uint64(sourcePID) > 0xffffffff {
		fmt.Fprintln(os.Stderr, "native-serve: invalid launch arguments")
		return 1
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	if err := serveNativeSession(ctx, uint32(sourcePID), session); err != nil {
		fmt.Fprintf(os.Stderr, "native-serve: %v\n", err)
		return 1
	}
	return 0
}

func serveNativeSession(ctx context.Context, sourcePID uint32, session string) error {
	source, err := observeNativeProcessPeer(sourcePID)
	if err != nil {
		return err
	}
	defer source.close()
	engine, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		return err
	}
	defer engine.close()
	if !engine.elevated || engine.sessionID != source.sessionID {
		return fmt.Errorf("native engine requires elevation in the source Windows session")
	}
	// Do not run existing USERPROFILE/HKCU collectors under a different user's
	// token. An original-user collector bridge is required for alternative-admin
	// UAC; until that bridge exists, this context is explicitly refused.
	if engine.userSID != source.userSID {
		return fmt.Errorf("native engine cannot use an alternative administrator without original-user collection")
	}
	enginePath, err := os.Executable()
	if err != nil {
		return err
	}
	manifest, err := readNativePackage(enginePath)
	if err != nil {
		return err
	}
	expectedShell := filepath.Join(filepath.Dir(enginePath), "Wootc.Shell.exe")
	if !strings.EqualFold(filepath.Clean(source.imagePath), filepath.Clean(expectedShell)) {
		return fmt.Errorf("native source process is outside this protected package")
	}
	name := `\\.\pipe\wootc-preview-` + session
	pipe, err := createNativePipe(name, source)
	if err != nil {
		return err
	}
	rawOwned := true
	defer func() {
		if rawOwned {
			windows.CloseHandle(pipe)
		}
	}()
	connectCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	err = connectNativePipe(connectCtx, pipe)
	cancel()
	if err != nil {
		return fmt.Errorf("native shell connection: %w", err)
	}
	connection := os.NewFile(uintptr(pipe), name)
	if connection == nil {
		return fmt.Errorf("native pipe handle could not become a connection")
	}
	rawOwned = false
	defer connection.Close()
	if err := connection.SetDeadline(time.Now().Add(10 * time.Second)); err != nil {
		return fmt.Errorf("native handshake requires bounded pipe IO: %w", err)
	}
	reader := bufio.NewReaderSize(connection, nativeHandshakeLimit)
	hello, err := readNativeHandshake(reader)
	if err != nil {
		return err
	}
	if err := validateNativeHandshake(hello, session, manifest.BuildID, manifest.BrandID); err != nil {
		return err
	}
	if err := verifyNativePipeClient(pipe, source); err != nil {
		return err
	}
	// Bind lifecycle/recovery reads to the uniquely trusted attempted install.
	// Competing, malformed or unsafe attempts cannot become a guessed route.
	if _, _, err := readStatusState(); err != nil {
		return fmt.Errorf("native startup installation discovery: %w", err)
	}
	// Neither launch arguments nor hello claims have reached installer state.
	if err := initializeStateTrust(); err != nil {
		return fmt.Errorf("native engine state trust: %w", err)
	}
	hello.Kind = "ready"
	if err := json.NewEncoder(connection).Encode(hello); err != nil {
		return err
	}
	if err := connection.SetDeadline(time.Time{}); err != nil {
		return err
	}
	runCtx, cancelRun := context.WithCancel(ctx)
	defer cancelRun()
	go func() {
		ticker := time.NewTicker(250 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-runCtx.Done():
				connection.Close()
				return
			case <-ticker.C:
				if err := source.checkAlive(); err != nil {
					cancelRun()
					connection.Close()
					return
				}
			}
		}
	}()
	initServeLogging()
	app := NewApp()
	app.startup(runCtx)
	return serveRPC(runCtx, app, reader, connection, true)
}
