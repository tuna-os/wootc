package main

// KnownFolders is the manifest Phase 1 leaves for the Phase-2 bridge.
type KnownFolders struct {
	// User is the Windows account these paths belong to.
	User string `json:"user"`
	// Folders maps a canonical folder name to its resolved WINDOWS path.
	Folders map[string]string `json:"folders"`
	// Redirected lists the folders whose resolved path is not the default
	// <profile>\<Folder>, purely so the reason is legible in a log.
	Redirected []string `json:"redirected,omitempty"`
	// CloudOnly counts dehydrated placeholders per folder: files that exist
	// as names but whose content is not on this disk.
	CloudOnly map[string]int `json:"cloudOnly,omitempty"`
}
