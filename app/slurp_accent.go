package main

import (
	"fmt"
	"strconv"
	"strings"
)

// accentFromColorization turns the DWM ColorizationColor value, as
// PowerShell prints it, into #RRGGBB. The value is an ARGB DWORD whose alpha
// byte is almost always 0x80 or more (Windows ships 0xC4…/0xFF…), so
// Get-ItemProperty returns it as a NEGATIVE Int32. Parsing it as unsigned
// rejected every real machine's accent; read it as a 32-bit pattern instead.
func accentFromColorization(raw string) (string, bool) {
	value := strings.TrimSpace(raw)
	if value == "" {
		return "", false
	}
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil || n < -1<<31 || n > 1<<32-1 {
		return "", false
	}
	argb := uint32(n)
	return fmt.Sprintf("#%02X%02X%02X", (argb>>16)&0xFF, (argb>>8)&0xFF, argb&0xFF), true
}
