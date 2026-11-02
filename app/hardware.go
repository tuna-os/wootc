package main

// Compatibility policy and glob vectors originate in tuna-os/bootc-migrate
// crates/bootc-migrate-core/src/hardware.rs, revision
// b2564052279b7075c5c2e082413300e208ce98be (MIT/Apache-2.0).
// Windows has no running Linux module inventory: devices are matched by PnP
// modalias instead. Missing identity fields remain unknown, never zero-filled.

import (
	"fmt"
	"sort"
	"strings"
)

type hardwareDevice struct {
	ID        string `json:"id"`
	Modalias  string `json:"modalias"`
	Class     uint32 `json:"class"`
	NVIDIA    bool   `json:"nvidia"`
	Uncertain bool   `json:"uncertain,omitempty"`
}

type hardwareAlias struct{ pattern, module string }

type hardwareKernel struct {
	version         string
	modules         map[string]string // normalized module name -> final overlay path
	builtin         map[string]bool
	aliases         []hardwareAlias
	firmware        map[string]bool
	moduleFirmware  map[string][]string
	firmwareUnknown map[string]bool
	partial         bool
}

type hardwareFinding struct {
	Severity string `json:"severity"`
	Subject  string `json:"subject"`
	Detail   string `json:"detail"`
}

type hardwareReport struct {
	Image          string            `json:"image"`
	TargetKernel   string            `json:"targetKernel,omitempty"`
	DevicesChecked int               `json:"devicesChecked"`
	Findings       []hardwareFinding `json:"findings"`
}

func hardwareModuleName(name string) string {
	return strings.ReplaceAll(strings.TrimSpace(name), "-", "_")
}

func hardwareFirmwareName(name string) string {
	name = strings.TrimLeft(strings.TrimSpace(name), "./")
	for _, suffix := range []string{".xz", ".zst", ".gz"} {
		if strings.HasSuffix(name, suffix) {
			return strings.TrimSuffix(name, suffix)
		}
	}
	return name
}

// Kernel globs differ from filepath.Match: '*' also matches '/' and negated
// classes use '!' as well as '^'. Backtracking is bounded to the last star.
func hardwareGlob(pattern, text string) bool {
	pi, ti, star, match := 0, 0, -1, 0
	for ti < len(text) {
		if pi < len(pattern) {
			switch pattern[pi] {
			case '*':
				star, match = pi+1, ti
				pi++
				continue
			case '?':
				pi++
				ti++
				continue
			case '[':
				if ok, n := hardwareGlobClass(pattern[pi:], text[ti]); ok {
					pi += n
					ti++
					continue
				}
			default:
				if pattern[pi] == text[ti] {
					pi++
					ti++
					continue
				}
			}
		}
		if star < 0 {
			return false
		}
		match++
		pi, ti = star, match
	}
	for pi < len(pattern) && pattern[pi] == '*' {
		pi++
	}
	return pi == len(pattern)
}

func hardwareGlobClass(p string, c byte) (bool, int) {
	i, negate, matched, first := 1, false, false, true
	if i < len(p) && (p[i] == '!' || p[i] == '^') {
		negate = true
		i++
	}
	for i < len(p) {
		if p[i] == ']' && !first {
			return matched != negate, i + 1
		}
		if i+2 < len(p) && p[i+1] == '-' && p[i+2] != ']' {
			matched = matched || (p[i] <= c && c <= p[i+2])
			i += 3
		} else {
			matched = matched || p[i] == c
			i++
		}
		first = false
	}
	return false, 0
}

func hardwareCritical(class uint32) bool {
	switch class >> 16 {
	case 0x01, 0x02, 0x03, 0x0d:
		return true
	case 0x0c:
		return (class>>8)&0xff == 3
	}
	return false
}

func (k hardwareKernel) hasModule(m string) bool {
	return k.modules[hardwareModuleName(m)] != "" || k.builtin[hardwareModuleName(m)]
}

func (k hardwareKernel) drivers(modalias string) []string {
	seen := map[string]bool{}
	for _, a := range k.aliases {
		if k.hasModule(a.module) && hardwareGlob(a.pattern, modalias) {
			seen[a.module] = true
		}
	}
	out := make([]string, 0, len(seen))
	for m := range seen {
		out = append(out, m)
	}
	sort.Strings(out)
	return out
}

func (k hardwareKernel) hasFirmware(name string) bool {
	name = hardwareFirmwareName(name)
	if !strings.ContainsAny(name, "*?[") {
		return k.firmware[name]
	}
	for f := range k.firmware {
		if hardwareGlob(name, f) {
			return true
		}
	}
	return false
}

// assessHardware never turns incomplete evidence into a blocking absence.
// Unlike the Linux source, Windows cannot identify the exact firmware variant
// currently loaded. All declared variants missing is a warning, not proof that
// this device requires firmware; verified Linux host firmware can only be
// assessed by the upstream Linux inventory reader.
func assessHardware(devices []hardwareDevice, k hardwareKernel) hardwareReport {
	r := hardwareReport{TargetKernel: k.version, Findings: []hardwareFinding{}}
	add := func(severity, subject, detail string) {
		if k.partial && severity == "blocking" {
			severity = "warning"
		}
		r.Findings = append(r.Findings, hardwareFinding{severity, subject, detail})
	}
	fb := ""
	for _, m := range []string{"simpledrm", "efifb", "simplefb", "vesafb", "ofdrm"} {
		if k.hasModule(m) {
			fb = m
			break
		}
	}
	for _, dev := range devices {
		if dev.Modalias == "" || dev.Uncertain {
			add("warning", dev.ID, "Hardware identity is incomplete; Linux driver compatibility could not be checked.")
			continue
		}
		r.DevicesChecked++
		drivers := k.drivers(dev.Modalias)
		if len(drivers) == 0 {
			severity := "warning"
			if hardwareCritical(dev.Class) {
				severity = "blocking"
			}
			detail := "No target kernel driver claims this hardware. Choose an image that supports this device before installing."
			if dev.Class>>16 == 3 && fb != "" {
				severity = "warning"
				detail = fmt.Sprintf("Only the firmware framebuffer (%s) is available: no graphics acceleration, firmware resolution, and one output only.", fb)
			}
			add(severity, dev.ID, detail)
			continue
		}
		if dev.NVIDIA {
			proprietary, nouveau := false, false
			for _, m := range drivers {
				proprietary = proprietary || strings.HasPrefix(m, "nvidia")
				nouveau = nouveau || m == "nouveau"
			}
			if nouveau && !proprietary {
				add("warning", dev.ID, "The target uses nouveau rather than the NVIDIA driver; CUDA, proprietary graphics features and performance may be lost. Choose an NVIDIA image to retain them.")
			}
		}
		anyViable, unknownFirmware := false, false
		for _, m := range drivers {
			if k.firmwareUnknown[m] {
				unknownFirmware = true
				continue
			}
			fw := k.moduleFirmware[m]
			if len(fw) == 0 {
				anyViable = true
				continue
			}
			for _, f := range fw {
				if k.hasFirmware(f) {
					anyViable = true
					break
				}
			}
		}
		if !anyViable {
			if unknownFirmware {
				add("warning", dev.ID, "Driver firmware requirements could not be read; firmware compatibility is unknown.")
			} else {
				add("warning", dev.ID, "The image contains none of the firmware declared by its matching drivers. Windows cannot establish which Linux firmware variant this hardware needs; verify support before rebooting.")
			}
		}
	}
	if k.partial {
		add("warning", "Incomplete target inventory", "Some image layers or kernel metadata could not be read, or multiple kernels are present. Missing items are not proven absent and do not block installation.")
	}
	if len(devices) == 0 {
		add("warning", "Host inventory", "No PCI/USB devices were identified; hardware compatibility is unknown.")
	}
	sort.SliceStable(r.Findings, func(i, j int) bool {
		return r.Findings[i].Severity == "blocking" && r.Findings[j].Severity != "blocking"
	})
	return r
}
