package main

import "testing"

func TestAccentFromColorization(t *testing.T) {
	for _, c := range []struct {
		raw, want string
		ok        bool
	}{
		// 0xC4E62D42 as PowerShell prints a DWORD with the high bit set: the
		// case every real Windows install is in, which the unsigned parse lost.
		{"-991548094\r\n", "#E62D42", true},
		{"-1", "#FFFFFF", true},
		{"4278221015", "#0078D7", true}, // 0xFF0078D7 printed unsigned
		{"7895160", "#787878", true},    // alpha 0
		{"", "", false},
		{"blue", "", false},
		{"4294967296", "", false},  // beyond 32 bits
		{"-2147483649", "", false}, // beyond Int32
	} {
		got, ok := accentFromColorization(c.raw)
		if got != c.want || ok != c.ok {
			t.Errorf("accentFromColorization(%q) = %q, %v; want %q, %v", c.raw, got, ok, c.want, c.ok)
		}
	}
}
