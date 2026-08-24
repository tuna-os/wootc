package main

import "testing"

func TestParseHexRGB(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		wantOK  bool
		r, g, b uint8
	}{
		{"black", "#000000", true, 0x00, 0x00, 0x00},
		{"white", "#ffffff", true, 0xff, 0xff, 0xff},
		{"uppercase hex", "#0A0A0F", true, 0x0a, 0x0a, 0x0f},
		{"mixed case", "#f6f6Fa", true, 0xf6, 0xf6, 0xfa},
		{"missing hash", "0a0a0f", false, 0, 0, 0},
		{"too short", "#0a0a0", false, 0, 0, 0},
		{"too long", "#0a0a0f0", false, 0, 0, 0},
		{"non-hex digits", "#gggggg", false, 0, 0, 0},
		{"empty string", "", false, 0, 0, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := parseHexRGB(c.in)
			if ok != c.wantOK {
				t.Fatalf("parseHexRGB(%q) ok = %v, want %v", c.in, ok, c.wantOK)
			}
			if !c.wantOK {
				if got != nil {
					t.Errorf("parseHexRGB(%q) = %+v, want nil on failure", c.in, got)
				}
				return
			}
			if got.R != c.r || got.G != c.g || got.B != c.b || got.A != 255 {
				t.Errorf("parseHexRGB(%q) = {R:%02x G:%02x B:%02x A:%d}, want {R:%02x G:%02x B:%02x A:255}",
					c.in, got.R, got.G, got.B, got.A, c.r, c.g, c.b)
			}
		})
	}
}
