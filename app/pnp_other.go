//go:build !windows

package main

func readHostHardware() HostHardware {
	return HostHardware{
		Modules:       make(map[string]HostModule),
		Complete:      false,
		IncompleteWhy: "the Windows Plug and Play inventory is available only on Windows",
	}
}
