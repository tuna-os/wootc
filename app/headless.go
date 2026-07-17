package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
)

// ── Headless CLI ─────────────────────────────────────────────────────────────
// `wootc.exe install --image ... --username ... --password ...` runs the
// exact production pipeline without a display, so E2E can drive Phase 1
// over QGA and enterprises get unattended installs. `wootc.exe status`
// prints the lifecycle state for test assertions. No subcommand → GUI.

func isHeadlessInvocation(args []string) bool {
	if len(args) < 2 {
		return false
	}
	switch args[1] {
	case "install", "status", "uninstall":
		return true
	}
	return false
}

// runHeadless dispatches the CLI subcommand and returns the process exit
// code. It never launches the webview.
func runHeadless(args []string) int {
	switch args[1] {
	case "install":
		return headlessInstall(args[2:])
	case "status":
		return headlessStatus()
	case "uninstall":
		if err := uninstall(context.Background()); err != nil {
			fmt.Fprintf(os.Stderr, "uninstall: %v\n", err)
			return 1
		}
		fmt.Println("uninstalled")
		return 0
	}
	return 2
}

func headlessInstall(args []string) int {
	fs := flag.NewFlagSet("install", flag.ContinueOnError)
	var cfg InstallConfig
	fs.StringVar(&cfg.ImageRef, "image", "", "bootc image reference (required)")
	fs.IntVar(&cfg.DiskSizeGB, "disk-size", 40, "root disk virtual size in GB")
	fs.StringVar(&cfg.Username, "username", "", "initial user name (required)")
	fs.StringVar(&cfg.Password, "password", "", "initial user password (required; hashed before persisting)")
	fs.StringVar(&cfg.Hostname, "hostname", "tunaos", "target hostname")
	fs.StringVar(&cfg.Bootloader, "bootloader", "grub2", "bootloader chain (grub2)")
	noReboot := fs.Bool("no-reboot", true, "do not reboot after arming (default true; pass -no-reboot=false to reboot)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if cfg.ImageRef == "" || cfg.Username == "" || cfg.Password == "" {
		fmt.Fprintln(os.Stderr, "install: -image, -username and -password are required")
		fs.Usage()
		return 2
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	err := runPipeline(ctx, cfg, func(e ProgressEvent) {
		if e.Error != "" {
			fmt.Fprintf(os.Stderr, "[wootc %3.0f%%] ERROR %s: %s\n", e.Percent, e.Step, e.Error)
			return
		}
		fmt.Printf("[wootc %3.0f%%] %s\n", e.Percent, e.Message)
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "install failed: %v\n", err)
		return 1
	}

	fmt.Println("install complete: system is armed to boot the deployer on next restart")
	if !*noReboot {
		if err := rebootWindows(); err != nil {
			fmt.Fprintf(os.Stderr, "reboot: %v\n", err)
			return 1
		}
	}
	return 0
}

func headlessStatus() int {
	s, ok := readState()
	if !ok {
		fmt.Println(`{"state":"absent"}`)
		return 0
	}
	data, err := marshalJSON(s)
	if err != nil {
		fmt.Fprintf(os.Stderr, "status: %v\n", err)
		return 1
	}
	fmt.Println(string(data))
	return 0
}
