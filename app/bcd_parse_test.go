package main

import "testing"

func TestBootmgrListsItself(t *testing.T) {
	cases := []struct {
		name string
		out  string
		want bool
	}{
		{"normal menu", `Windows Boot Manager
--------------------
identifier              {bootmgr}
device                  partition=\Device\HarddiskVolume1
description             Windows Boot Manager
locale                  en-US
default                 {current}
displayorder            {current}
toolsdisplayorder       {memdiag}
timeout                 30
`, false},
		{"self reference first (the #551 bug)", `identifier              {bootmgr}
displayorder            {bootmgr}
                        {current}
toolsdisplayorder       {memdiag}
`, true},
		{"self reference on a continuation line", "identifier              {bootmgr}\r\ndisplayorder            {current}\r\n                        {bootmgr}\r\ntimeout                 30\r\n", true},
		{"bootmgr only in the identifier and toolsdisplayorder", `identifier              {bootmgr}
displayorder            {current}
toolsdisplayorder       {bootmgr}
`, false},
		{"no displayorder", "identifier {bootmgr}\n", false},
		{"empty", "", false},
	}
	for _, c := range cases {
		if got := bootmgrListsItself(c.out); got != c.want {
			t.Errorf("%s: got %v, want %v", c.name, got, c.want)
		}
	}
}

func TestParseESPDiscovery(t *testing.T) {
	cases := []struct {
		out      string
		letter   string
		assigned bool
	}{
		{"S\r\n", "S", false},
		{"ASSIGNED:Z\r\n", "Z", true},
		{"\x00", "", false},
		{"WOOTC_NO_ESP\n", "WOOTC_NO_ESP", false},
	}
	for _, c := range cases {
		l, a := parseESPDiscovery(c.out)
		if l != c.letter || a != c.assigned {
			t.Errorf("parseESPDiscovery(%q) = %q, %v; want %q, %v", c.out, l, a, c.letter, c.assigned)
		}
	}
}
