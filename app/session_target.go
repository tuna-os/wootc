package main

import "context"

// SessionImportRequest is a one-shot explicit action. Password is neither
// stored in App state nor written to the import ledger. Packaging and backend
// must match the actual target Chrome installation/password-store selection.
type SessionImportRequest struct {
	App           string `json:"app"`
	Consent       bool   `json:"consent"`
	Password      string `json:"password"`
	Backend       string `json:"backend"`
	Packaging     string `json:"packaging"`
	SourceProfile string `json:"sourceProfile"`
	TargetProfile string `json:"targetProfile"`
}

// Rewritten is a data-format outcome, not evidence that a service accepted a
// session. This implementation never produces imported/verified automatically.
type SessionImportResult struct {
	App                 string   `json:"app"`
	State               string   `json:"state"`
	Verified            bool     `json:"verified"`
	Reason              string   `json:"reason"`
	CookiesWritten      int      `json:"cookiesWritten"`
	LocalRecordsWritten int      `json:"localRecordsWritten"`
	RecordsPreserved    int      `json:"recordsPreserved"`
	Backups             []string `json:"backups,omitempty"`
}

func (a *App) ImportAppSession(request SessionImportRequest) (SessionImportResult, error) {
	ctx := a.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	return importSelectedSession(ctx, request)
}
