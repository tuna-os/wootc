package main

import (
	"errors"
	"strings"
	"testing"
)

func TestBuilderRequiresPositiveCompletion(t *testing.T) {
	for _, tc := range []struct {
		name, stream string
		processErr   error
		ok           bool
	}{
		{"no guest", "", nil, false},
		{"progress only", "{\"step\":\"finalizing\",\"pct\":100}\n", nil, false},
		{"failed guest powers off normally", "{\"step\":\"error\",\"msg\":\"disk full\"}\n", nil, false},
		{"error cannot be erased by success", "{\"step\":\"error\"}\nSTATUS=SUCCESS\n", nil, false},
		{"successful guest but failed process", "STATUS=SUCCESS\n", errors.New("killed"), false},
		{"exact success marker", "STATUS=SUCCESS\n", nil, true},
		{"misleading text", "log: STATUS=SUCCESS\n", nil, false},
		{"oversized IPC", strings.Repeat("x", 70000) + "\nSTATUS=SUCCESS\n", nil, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := readBuilderProgress(strings.NewReader(tc.stream), func(VMEvent) {})
			if got := r.verify(tc.processErr); (got == nil) != tc.ok {
				t.Fatalf("completion=%v want success=%v", got, tc.ok)
			}
		})
	}
}
func TestVMDiskUsesRawAndEscapesKeyval(t *testing.T) {
	got := vmDiskDrive(`C:\Users\A,B\root.disk`)
	if got != `file=C:\Users\A,,B\root.disk,format=raw,if=virtio` {
		t.Fatal(got)
	}
}
