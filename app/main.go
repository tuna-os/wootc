package main

import (
	"fmt"
	"os"
)

func main() {
	// Native transport authenticates the OS peer and protected package before
	// any installer-state creation.
	if len(os.Args) > 1 && os.Args[1] == "--native-serve" {
		os.Exit(runNativeServe(os.Args))
	}

	if err := initializeStateTrustForInvocation(os.Args); err != nil {
		reportStateTrustFailure(err)
		os.Exit(1)
	}

	// Headless subcommands (install/status/uninstall) run the production
	// pipeline. The graphical installer is the native WinUI shell; this
	// binary is the engine behind it.
	if isHeadlessInvocation(os.Args) {
		os.Exit(runHeadless(os.Args))
	}

	fmt.Fprintln(os.Stderr, "wootc is the install engine. Run the native setup (<Product>-Installer-Setup.exe) for the graphical installer, or use `wootc install|status|uninstall` headless.")
	os.Exit(2)
}
