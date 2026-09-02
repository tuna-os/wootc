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
	case "install", "status", "uninstall", "recover":
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
	case "recover":
		return headlessRecover(args[2:])
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
	fs.StringVar(&cfg.Bootloader, "bootloader", "auto", "bootloader chain (auto|grub2|systemd-boot; auto lets the deployer detect the image's backend)")
	noReboot := fs.Bool("no-reboot", true, "do not reboot after arming (default true; pass -no-reboot=false to reboot)")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if cfg.ImageRef == "" || cfg.Username == "" || cfg.Password == "" {
		fmt.Fprintln(os.Stderr, "install: -image, -username and -password are required")
		fs.Usage()
		return 2
	}
	// headless bypasses StartInstall, so validate the chain here too rather
	// than letting a typo'd -bootloader fall through to the auto path.
	bootloader, err := normalizeBootloader(cfg.Bootloader)
	if err != nil {
		fmt.Fprintf(os.Stderr, "install: %v\n", err)
		return 2
	}
	cfg.Bootloader = bootloader

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	err = runPipeline(ctx, cfg, func(e ProgressEvent) {
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

func headlessRecover(args []string) int {
	fs := flag.NewFlagSet("recover", flag.ContinueOnError)
	startup := fs.Bool("startup", false, "run startup recovery guard logic (decision table)")
	prompt := fs.Bool("prompt", false, "run logon recovery prompt check")
	status := fs.Bool("status", false, "print recovery verdict JSON")
	tryAgain := fs.Bool("try-again", false, "re-arm from armed.json and reboot")
	repairBoot := fs.Bool("repair-boot", false, "re-stage ESP, re-arm BCD and reboot")
	remove := fs.Bool("remove", false, "uninstall wootc")
	noReboot := fs.Bool("no-reboot", false, "do not reboot after try-again or repair-boot")

	if err := fs.Parse(args); err != nil {
		return 2
	}

	if *startup {
		if err := runRecoverStartup(); err != nil {
			fmt.Fprintf(os.Stderr, "recover startup: %v\n", err)
			return 1
		}
		fmt.Println("recover startup complete")
		return 0
	}

	if *prompt {
		if err := runRecoverPrompt(); err != nil {
			fmt.Fprintf(os.Stderr, "recover prompt: %v\n", err)
			return 1
		}
		return 0
	}

	if *status {
		v, err := readRecoveryVerdict()
		if err != nil {
			fmt.Println(`{"verdict":"none"}`)
			return 0
		}
		data, err := marshalJSON(v)
		if err != nil {
			fmt.Fprintf(os.Stderr, "recover status: %v\n", err)
			return 1
		}
		fmt.Println(string(data))
		return 0
	}

	if *tryAgain {
		if err := tryAgainFromArmed(*noReboot); err != nil {
			fmt.Fprintf(os.Stderr, "recover try-again: %v\n", err)
			return 1
		}
		fmt.Println("try-again complete")
		return 0
	}

	if *repairBoot {
		if err := repairBootFromArmed(*noReboot); err != nil {
			fmt.Fprintf(os.Stderr, "recover repair-boot: %v\n", err)
			return 1
		}
		fmt.Println("repair-boot complete")
		return 0
	}

	if *remove {
		if err := uninstall(context.Background()); err != nil {
			fmt.Fprintf(os.Stderr, "recover remove: %v\n", err)
			return 1
		}
		fmt.Println("removed")
		return 0
	}

	// Default when no flag provided: run startup logic
	if err := runRecoverStartup(); err != nil {
		fmt.Fprintf(os.Stderr, "recover: %v\n", err)
		return 1
	}
	return 0
}
