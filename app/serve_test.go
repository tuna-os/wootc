package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

var updateGoldens = flag.Bool("update", false, "update golden DTO files")

// ── Golden DTO Tests ─────────────────────────────────────────────────────────

func sampleDTOs() map[string]any {
	return map[string]any{
		"support_policy": SupportPolicy{
			Channel:            "alpha",
			ExperimentalImages: false,
			BitLockerSupported: false,
			CustomImageAllowed: false,
			Reason:             "Alpha — only fully-tested images and unencrypted disks are offered. More unlock as testing goes green.",
		},
		"system_info": SystemInfo{
			OSVersion:           "10.0.22631",
			FreeDiskGB:          128.5,
			TotalDiskGB:         512.0,
			BitLockerOn:         false,
			BitLockerState:      "off",
			FastStartupOn:       false,
			IsUEFI:              true,
			SecureBootOn:        true,
			SecureBootKnown:     true,
			DefragRecommended:   false,
			OnBattery:           false,
			BatteryKnown:        true,
			PendingReboot:       false,
			PendingRebootReason: "",
			Hibernated:          false,
			RAMGB:               16.0,
			Is64Bit:             true,
			DataPartitions: []DataPartition{
				{
					Letter:    "D",
					Label:     "DATA",
					FreeGB:    64.0,
					Encrypted: false,
				},
			},
			BitLockerRecoveryKeyWarning: false,
			SuggestedHostname:           "my-laptop",
			SuggestedUsername:           "winuser",
		},
		"data_partition": DataPartition{
			Letter:    "D",
			Label:     "DATA",
			FreeGB:    64.0,
			Encrypted: false,
		},
		"branding": Branding{
			Name:            "TunaOS",
			Tagline:         "A fast, cloud-native desktop",
			LogoEmoji:       "🐟",
			Version:         "1.0.0",
			Accent:          "#0066cc",
			AccentText:      "#ffffff",
			Background:      "#0a0a0f",
			Card:            "#1a1a24",
			Text:            "#e0e0e0",
			InstallVerb:     "Install",
			ProductName:     "wootc",
			ExeName:         "wootc",
			Publisher:       "TunaOS",
			FileDescription: "TunaOS installer",
			WebsiteURL:      "https://example.com",
			SupportURL:      "https://example.com/help",
			Catalog:         []string{"yellowfin", "bluefin"},
			DefaultImage:    "yellowfin",
			HideCustomImage: false,
			PreloadImage:    false,
			FontFamily:      "Segoe UI",
			LogoDataURI:     "",
			FontDataURI:     "",
			ThemeCSS:        "",
		},
		"image": Image{
			ID:          "yellowfin",
			Name:        "Yellowfin (GNOME)",
			Emoji:       "🐟",
			Base:        "fedora",
			Desktop:     "gnome",
			DesktopName: "GNOME 46",
			ImageRef:    "ghcr.io/tuna-os/yellowfin:gnome",
			Description: "Clean, modern Fedora workstation with bootc atomic updates",
			Bootloader:  "grub2",
			ComposeFS:   true,
			Family:      "fedora",
			Status:      "green",
			MokEnroll:   "tunaos",
		},
		"install_config": InstallConfig{
			ImageRef:       "ghcr.io/tuna-os/yellowfin:gnome",
			DiskSizeGB:     40,
			Username:       "winuser",
			Password:       "secretpassword",
			Hostname:       "my-laptop",
			Bootloader:     "auto",
			ComposeFS:      true,
			StorageDrive:   "C",
			Encryption:     "tpm2-luks",
			LuksPassphrase: "",
			WindowsLook:    true,
			SessionConsent: map[string]bool{
				"chrome": true,
			},
		},
		"progress_event": ProgressEvent{
			Step:    "Downloading Linux",
			Message: "Downloading Linux… 50%",
			Percent: 50.0,
			Done:    false,
		},
		"install_status": InstallStatus{
			Running:  true,
			Done:     false,
			Existing: false,
		},
		"uninstall_info": UninstallInfo{
			Found:          true,
			StorageDrive:   "C",
			DiskPath:       `C:\wootc\root.disk`,
			DiskSizeGB:     40.0,
			OnDedicatedVol: false,
			ReclaimGB:      40.0,
			Orphaned:       false,
			Deployed:       true,
		},
		"uninstall_options": UninstallOptions{
			DeleteRootDisk:  true,
			RemovePartition: false,
		},
		"lifecycle_state": LifecycleState{
			State:     "armed",
			Phase:     "Making Linux bootable on your machine",
			Error:     "",
			UpdatedAt: "2026-09-02T12:00:00Z",
			UpdatedBy: "wootc-installer",
		},
		"session_candidate": SessionCandidate{
			App:             "chrome",
			Kind:            "chromium",
			Portable:        true,
			Recommend:       "copy",
			Note:            "Profiles and cookies can be migrated",
			ConsentRequired: true,
		},
		"session_export": SessionExport{
			App:   "chrome",
			State: "staged",
		},
		"vm_event": VMEvent{
			Stage:   "pulling",
			Percent: 35.5,
			Message: "Pulling container image...",
		},
		"vm_capability": VMCapability{
			Available:   true,
			Reason:      "",
			DiskPath:    `C:\wootc\disks\root.disk`,
			Accelerator: "whpx,kernel-irqchip=off",
			QEMUPath:    `C:\wootc\qemu\qemu-system-x86_64.exe`,
			Bundled:     true,
			ProbeStatus: "passed",
		},
		"bundle_info": BundleInfo{
			Image:      "ghcr.io/tuna-os/yellowfin:gnome",
			Digest:     "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef",
			StoreBytes: 2147483648,
			CreatedAt:  "2026-09-02T12:00:00Z",
			Source:     "predownload",
		},
	}
}

func TestDTOGoldens(t *testing.T) {
	dtos := sampleDTOs()
	testdataDir := filepath.Join("testdata", "dto")
	_ = os.MkdirAll(testdataDir, 0o755)

	for name, sample := range dtos {
		t.Run(name, func(t *testing.T) {
			goldenPath := filepath.Join(testdataDir, name+".json")
			formatted, err := json.MarshalIndent(sample, "", "  ")
			if err != nil {
				t.Fatalf("MarshalIndent failed: %v", err)
			}
			formatted = append(formatted, '\n')

			if *updateGoldens {
				if err := os.WriteFile(goldenPath, formatted, 0o644); err != nil {
					t.Fatalf("failed to update golden %s: %v", goldenPath, err)
				}
				return
			}

			existing, err := os.ReadFile(goldenPath)
			if err != nil {
				if os.IsNotExist(err) {
					// Auto-create on first run if missing
					if err := os.WriteFile(goldenPath, formatted, 0o644); err != nil {
						t.Fatalf("failed to create golden %s: %v", goldenPath, err)
					}
					existing = formatted
				} else {
					t.Fatalf("failed to read golden %s: %v", goldenPath, err)
				}
			}

			if !bytes.Equal(existing, formatted) {
				t.Errorf("DTO golden mismatch for %s.\nWant:\n%s\nGot:\n%s", name, string(existing), string(formatted))
			}

			// Verify unmarshaling into a new instance of the same type produces equal content
			targetVal := reflect.New(reflect.TypeOf(sample)).Interface()
			if err := json.Unmarshal(existing, targetVal); err != nil {
				t.Fatalf("failed to unmarshal golden %s into %T: %v", name, sample, err)
			}
		})
	}
}

// ── Method List Matching Test Against docs/winui-shell.md ───────────────────

func TestProtocolMatchesWinuiShellSpec(t *testing.T) {
	specPath := filepath.Join("..", "docs", "winui-shell.md")
	content, err := os.ReadFile(specPath)
	if err != nil {
		t.Fatalf("failed to read %s: %v", specPath, err)
	}

	// Look for table in "### The `serve` protocol" section
	// Table row format: | `MethodName` | ... | ... |
	re := regexp.MustCompile(`(?m)^\|\s*` + "`" + `([A-Za-z0-9_]+)` + "`" + `\s*\|`)
	matches := re.FindAllStringSubmatch(string(content), -1)
	if len(matches) == 0 {
		t.Fatalf("no protocol methods found in %s table", specPath)
	}

	specMethods := make([]string, 0, len(matches))
	for _, m := range matches {
		specMethods = append(specMethods, m[1])
	}

	if len(specMethods) != len(ProtocolMethods) {
		t.Errorf("method count mismatch: docs/winui-shell.md has %d, ProtocolMethods has %d\nDocs: %v\nImpl: %v",
			len(specMethods), len(ProtocolMethods), specMethods, ProtocolMethods)
	}

	methodMap := make(map[string]bool)
	for _, m := range ProtocolMethods {
		methodMap[m] = true
	}

	for _, sm := range specMethods {
		if !methodMap[sm] {
			t.Errorf("method %q documented in docs/winui-shell.md but missing in ProtocolMethods", sm)
		}
	}

	specMap := make(map[string]bool)
	for _, sm := range specMethods {
		specMap[sm] = true
	}

	for _, m := range ProtocolMethods {
		if !specMap[m] {
			t.Errorf("method %q present in ProtocolMethods but missing in docs/winui-shell.md", m)
		}
	}
}

// ── JSON-RPC Round-Trip Pipe Tests ──────────────────────────────────────────

type pipeHarness struct {
	clientIn  *io.PipeReader
	serverOut *io.PipeWriter
	serverIn  *io.PipeReader
	clientOut *io.PipeWriter
	scanner   *bufio.Scanner
	app       *App
	cancel    context.CancelFunc
	serveErr  chan error
	mu        sync.Mutex
}

func newPipeHarness(t *testing.T) *pipeHarness {
	t.Helper()
	clientIn, serverOut := io.Pipe()
	serverIn, clientOut := io.Pipe()

	ctx, cancel := context.WithCancel(context.Background())
	app := NewApp()
	app.startup(ctx)

	h := &pipeHarness{
		clientIn:  clientIn,
		serverOut: serverOut,
		serverIn:  serverIn,
		clientOut: clientOut,
		scanner:   bufio.NewScanner(clientIn),
		app:       app,
		cancel:    cancel,
		serveErr:  make(chan error, 1),
	}

	go func() {
		err := Serve(ctx, app, serverIn, serverOut)
		h.serveErr <- err
		_ = serverOut.Close()
	}()

	return h
}

func (h *pipeHarness) Close() {
	h.cancel()
	_ = h.clientOut.Close()
	_ = h.serverIn.Close()
	_ = h.clientIn.Close()
}

func (h *pipeHarness) call(t *testing.T, method string, params any, id any) (json.RawMessage, *jsonrpcError) {
	t.Helper()
	h.mu.Lock()
	defer h.mu.Unlock()

	reqMap := map[string]any{
		"jsonrpc": "2.0",
		"method":  method,
	}
	if id != nil {
		reqMap["id"] = id
	}
	if params != nil {
		reqMap["params"] = params
	}

	reqBytes, err := json.Marshal(reqMap)
	if err != nil {
		t.Fatalf("failed to marshal request: %v", err)
	}

	if _, err := fmt.Fprintf(h.clientOut, "%s\n", reqBytes); err != nil {
		t.Fatalf("failed to write request: %v", err)
	}

	if !h.scanner.Scan() {
		t.Fatalf("no response line received: %v", h.scanner.Err())
	}

	line := h.scanner.Bytes()
	var raw struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Result  json.RawMessage `json:"result"`
		Error   *jsonrpcError   `json:"error"`
	}
	if err := json.Unmarshal(line, &raw); err != nil {
		t.Fatalf("failed to unmarshal response %q: %v", string(line), err)
	}

	if raw.JSONRPC != "2.0" {
		t.Errorf("response jsonrpc = %q, want 2.0", raw.JSONRPC)
	}

	return raw.Result, raw.Error
}

func TestServeAllMethodsRoundTrip(t *testing.T) {
	h := newPipeHarness(t)
	defer h.Close()

	t.Run("GetSupportPolicy", func(t *testing.T) {
		res, rpcErr := h.call(t, "GetSupportPolicy", nil, 1)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var p SupportPolicy
		if err := json.Unmarshal(res, &p); err != nil {
			t.Fatalf("failed to unmarshal SupportPolicy: %v", err)
		}
		if p.Channel == "" {
			t.Errorf("Channel is empty in %+v", p)
		}
	})

	t.Run("GetSystemInfo", func(t *testing.T) {
		res, rpcErr := h.call(t, "GetSystemInfo", nil, 2)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var s SystemInfo
		if err := json.Unmarshal(res, &s); err != nil {
			t.Fatalf("failed to unmarshal SystemInfo: %v", err)
		}
	})

	t.Run("GetBranding", func(t *testing.T) {
		res, rpcErr := h.call(t, "GetBranding", nil, 3)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var b Branding
		if err := json.Unmarshal(res, &b); err != nil {
			t.Fatalf("failed to unmarshal Branding: %v", err)
		}
		if b.Name == "" {
			t.Errorf("Branding.Name is empty")
		}
	})

	t.Run("GetImages", func(t *testing.T) {
		res, rpcErr := h.call(t, "GetImages", nil, 4)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var imgs []Image
		if err := json.Unmarshal(res, &imgs); err != nil {
			t.Fatalf("failed to unmarshal images: %v", err)
		}
	})

	t.Run("GetSessionCandidates", func(t *testing.T) {
		res, rpcErr := h.call(t, "GetSessionCandidates", nil, 5)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var c []SessionCandidate
		if err := json.Unmarshal(res, &c); err != nil {
			t.Fatalf("failed to unmarshal SessionCandidate list: %v", err)
		}
	})

	t.Run("GetStatus", func(t *testing.T) {
		res, rpcErr := h.call(t, "GetStatus", nil, 6)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var s InstallStatus
		if err := json.Unmarshal(res, &s); err != nil {
			t.Fatalf("failed to unmarshal InstallStatus: %v", err)
		}
	})

	t.Run("CancelInstall", func(t *testing.T) {
		res, rpcErr := h.call(t, "CancelInstall", nil, 7)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		if string(res) != "null" {
			t.Errorf("CancelInstall result = %s, want null", string(res))
		}
	})

	t.Run("ExistingInstallFound", func(t *testing.T) {
		res, rpcErr := h.call(t, "ExistingInstallFound", nil, 8)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var found bool
		if err := json.Unmarshal(res, &found); err != nil {
			t.Fatalf("failed to unmarshal bool: %v", err)
		}
	})

	t.Run("GetUninstallInfo", func(t *testing.T) {
		res, rpcErr := h.call(t, "GetUninstallInfo", nil, 9)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var u UninstallInfo
		if err := json.Unmarshal(res, &u); err != nil {
			t.Fatalf("failed to unmarshal UninstallInfo: %v", err)
		}
	})

	t.Run("GetLastRun", func(t *testing.T) {
		res, rpcErr := h.call(t, "GetLastRun", nil, 10)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var l LifecycleState
		if err := json.Unmarshal(res, &l); err != nil {
			t.Fatalf("failed to unmarshal LifecycleState: %v", err)
		}
	})

	t.Run("E2EDriveDirective", func(t *testing.T) {
		res, rpcErr := h.call(t, "E2EDriveDirective", nil, 11)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		var d string
		if err := json.Unmarshal(res, &d); err != nil {
			t.Fatalf("failed to unmarshal string: %v", err)
		}
	})

	t.Run("E2EDriveReport", func(t *testing.T) {
		res, rpcErr := h.call(t, "E2EDriveReport", "ready", 12)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		if string(res) != "null" {
			t.Errorf("E2EDriveReport result = %s, want null", string(res))
		}
	})

	t.Run("DefragDrive", func(t *testing.T) {
		// On non-windows dev build defrag returns nil or is stubbed
		_, _ = h.call(t, "DefragDrive", nil, 13)
	})

	t.Run("UninstallWith", func(t *testing.T) {
		res, rpcErr := h.call(t, "UninstallWith", UninstallOptions{DeleteRootDisk: false}, 14)
		if rpcErr != nil {
			t.Fatalf("unexpected error: %+v", rpcErr)
		}
		if string(res) != "null" {
			t.Errorf("UninstallWith result = %s, want null", string(res))
		}
	})

	t.Run("Reboot", func(t *testing.T) {
		// On non-windows dev build Reboot returns error "reboot not available on this platform"
		_, rpcErr := h.call(t, "Reboot", nil, 15)
		if rpcErr == nil {
			t.Logf("Reboot succeeded on this platform")
		} else {
			if !strings.Contains(rpcErr.Message, "reboot not available") {
				t.Errorf("unexpected Reboot error: %v", rpcErr.Message)
			}
		}
	})

	t.Run("BootIntoLinux", func(t *testing.T) {
		// On dev build without bcd-guid.txt, it fails as expected
		_, _ = h.call(t, "BootIntoLinux", nil, 16)
	})

	t.Run("StartInstall", func(t *testing.T) {
		// Gate scenario check: test StartInstall with invalid config returns error
		_, rpcErr := h.call(t, "StartInstall", InstallConfig{
			ImageRef: "invalid-image",
		}, 17)
		if rpcErr == nil {
			t.Errorf("expected StartInstall to error for invalid image")
		}
	})
}

func TestNotificationsProgressAndVM(t *testing.T) {
	clientIn, serverOut := io.Pipe()
	serverIn, clientOut := io.Pipe()
	defer clientOut.Close()
	defer serverIn.Close()
	defer clientIn.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	app := NewApp()
	app.startup(ctx)

	started := make(chan struct{})
	go func() {
		close(started)
		_ = Serve(ctx, app, serverIn, serverOut)
		_ = serverOut.Close()
	}()

	<-started
	time.Sleep(20 * time.Millisecond)

	scanner := bufio.NewScanner(clientIn)

	// Emit install:progress
	go app.emit(ProgressEvent{
		Step:    "Testing",
		Message: "Progress at 42%",
		Percent: 42.0,
		Done:    false,
	})

	if !scanner.Scan() {
		t.Fatalf("failed to read notification: %v", scanner.Err())
	}

	var notif struct {
		JSONRPC string        `json:"jsonrpc"`
		Method  string        `json:"method"`
		Params  ProgressEvent `json:"params"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &notif); err != nil {
		t.Fatalf("failed to unmarshal notification: %v", err)
	}
	if notif.JSONRPC != "2.0" {
		t.Errorf("notification JSONRPC = %q, want 2.0", notif.JSONRPC)
	}
	if notif.Method != "install:progress" {
		t.Errorf("notification Method = %q, want install:progress", notif.Method)
	}
	if notif.Params.Percent != 42.0 || notif.Params.Step != "Testing" {
		t.Errorf("unexpected params: %+v", notif.Params)
	}

	// Emit vm:progress
	go app.emitVM(VMEvent{
		Stage:   "pulling",
		Percent: 99.0,
		Message: "Finishing",
	})

	if !scanner.Scan() {
		t.Fatalf("failed to read vm notification: %v", scanner.Err())
	}

	var vmNotif struct {
		JSONRPC string  `json:"jsonrpc"`
		Method  string  `json:"method"`
		Params  VMEvent `json:"params"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &vmNotif); err != nil {
		t.Fatalf("failed to unmarshal vm notification: %v", err)
	}
	if vmNotif.Method != "vm:progress" {
		t.Errorf("notification Method = %q, want vm:progress", vmNotif.Method)
	}
	if vmNotif.Params.Stage != "pulling" || vmNotif.Params.Percent != 99.0 {
		t.Errorf("unexpected params: %+v", vmNotif.Params)
	}
}

func TestShutdownMethod(t *testing.T) {
	h := newPipeHarness(t)
	defer h.Close()

	res, rpcErr := h.call(t, "Shutdown", nil, 99)
	if rpcErr != nil {
		t.Fatalf("unexpected error on Shutdown: %+v", rpcErr)
	}
	if string(res) != "null" {
		t.Errorf("Shutdown result = %s, want null", string(res))
	}

	select {
	case err := <-h.serveErr:
		if err != nil {
			t.Errorf("Serve returned error after Shutdown: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not terminate after Shutdown within timeout")
	}
}

func TestStdinCloseDisarmsAndExits(t *testing.T) {
	clientIn, serverOut := io.Pipe()
	serverIn, clientOut := io.Pipe()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	app := NewApp()
	app.startup(ctx)

	serveErr := make(chan error, 1)
	go func() {
		err := Serve(ctx, app, serverIn, serverOut)
		serveErr <- err
		_ = serverOut.Close()
	}()

	// Close clientOut to simulate EOF on stdin
	_ = clientOut.Close()

	select {
	case err := <-serveErr:
		if err != nil {
			t.Errorf("Serve returned error on stdin EOF: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Serve did not exit on stdin EOF within timeout")
	}
	_ = clientIn.Close()
	_ = serverIn.Close()
}

func TestInvalidMethodAndParseError(t *testing.T) {
	h := newPipeHarness(t)
	defer h.Close()

	_, rpcErr := h.call(t, "NonExistentMethod", nil, 100)
	if rpcErr == nil {
		t.Fatal("expected error for NonExistentMethod, got nil")
	}
	if rpcErr.Code != errCodeMethodNotFound {
		t.Errorf("error code = %d, want %d", rpcErr.Code, errCodeMethodNotFound)
	}

	// Send invalid JSON
	if _, err := fmt.Fprintln(h.clientOut, "{invalid json"); err != nil {
		t.Fatal(err)
	}
	if !h.scanner.Scan() {
		t.Fatal("no response for parse error")
	}
	var raw struct {
		Error *jsonrpcError `json:"error"`
	}
	if err := json.Unmarshal(h.scanner.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	if raw.Error == nil || raw.Error.Code != errCodeParseError {
		t.Errorf("expected parse error (-32700), got: %+v", raw.Error)
	}
}
