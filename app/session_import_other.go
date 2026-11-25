//go:build !linux

package main

import (
	"context"
	"fmt"
)

func importSelectedSession(context.Context, SessionImportRequest) (SessionImportResult, error) {
	return SessionImportResult{}, fmt.Errorf("session import is only available in the installed Linux user's desktop")
}
