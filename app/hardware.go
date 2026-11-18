package main

import (
	"fmt"
	"sort"
	"strings"
	"unicode/utf8"
)

// HardwareSeverity is the impact of a target-image compatibility finding.
type HardwareSeverity string

const (
	HardwareNote     HardwareSeverity = "note"
	HardwareWarning  HardwareSeverity = "warning"
	HardwareBlocking HardwareSeverity = "blocking"
)

// HardwareFinding describes one device or firmware compatibility result.
type HardwareFinding struct {
	Severity HardwareSeverity `json:"severity"`
	Subject  string           `json:"subject"`
	Detail   string           `json:"detail"`
}

// HardwareReport is the pure result of comparing the current PC with a target kernel.
type HardwareReport struct {
	TargetKernel   string            `json:"targetKernel,omitempty"`
	DevicesChecked int               `json:"devicesChecked"`
	Findings       []HardwareFinding `json:"findings"`
}

func (r HardwareReport) hasBlocking() bool {
	for _, finding := range r.Findings {
		if finding.Severity == HardwareBlocking {
			return true
		}
	}
	return false
}

const (
	maxHardwareWarningCount = 32
	maxHardwareMessageRunes = 1800 // safely below the native protocol's 4096 UTF-16-unit limit
)

func (r HardwareReport) warningMessages() []string {
	var messages []string
	for _, finding := range r.Findings {
		if finding.Severity == HardwareWarning {
			messages = append(messages, truncateHardwareMessage(finding.Subject+": "+finding.Detail))
		}
	}
	if len(messages) > maxHardwareWarningCount {
		remaining := len(messages) - (maxHardwareWarningCount - 1)
		messages = append(messages[:maxHardwareWarningCount-1], fmt.Sprintf("%d additional hardware warnings were omitted.", remaining))
	}
	return messages
}

func (r HardwareReport) blockingError() error {
	var messages []string
	for _, finding := range r.Findings {
		if finding.Severity == HardwareBlocking {
			messages = append(messages, finding.Subject+": "+finding.Detail)
		}
	}
	if len(messages) == 0 {
		return nil
	}
	return fmt.Errorf("the selected Linux image is not compatible with this PC: %s Choose an image that includes this hardware support and try again", truncateHardwareMessage(strings.Join(messages, " ")))
}

func truncateHardwareMessage(message string) string {
	if utf8.RuneCountInString(message) <= maxHardwareMessageRunes {
		return message
	}
	runes := 0
	for index := range message {
		if runes == maxHardwareMessageRunes-1 {
			return message[:index] + "…"
		}
		runes++
	}
	return message
}

// TargetKernel is the driver and firmware inventory merged from the target OCI layers.
type TargetKernel struct {
	KVersion      string
	Modules       map[string]struct{}
	Builtin       map[string]struct{}
	Aliases       []moduleAlias
	Firmware      map[string]struct{}
	LayersSkipped int
}

type moduleAlias struct {
	Pattern string
	Module  string
}

func (k TargetKernel) hasModule(module string) bool {
	module = normalizeModule(module)
	_, loadable := k.Modules[module]
	_, builtin := k.Builtin[module]
	return loadable || builtin
}

func (k TargetKernel) aliasDrivers(modalias string) []string {
	seen := make(map[string]struct{})
	var drivers []string
	for _, alias := range k.Aliases {
		if globMatch(alias.Pattern, modalias) {
			if _, ok := seen[alias.Module]; !ok {
				seen[alias.Module] = struct{}{}
				drivers = append(drivers, alias.Module)
			}
		}
	}
	sort.Strings(drivers)
	return drivers
}

func (k TargetKernel) hasFirmware(name string) bool {
	name = normalizeFirmware(name)
	if strings.ContainsAny(name, "*?[") {
		for candidate := range k.Firmware {
			if globMatch(name, candidate) {
				return true
			}
		}
		return false
	}
	_, ok := k.Firmware[name]
	return ok
}

// HostDevice is a Windows PnP device translated to a Linux modalias. Module is
// present only when Windows identifies a driver with a meaningful Linux peer
// (notably the proprietary NVIDIA stack). ModuleKnown distinguishes a known
// built-in host driver (empty Module, ignored like bootc-migrate) from Windows'
// normal case where the Linux host module is unknown.
type HostDevice struct {
	Bus         string  `json:"bus"`
	ID          string  `json:"id"`
	Modalias    string  `json:"modalias,omitempty"`
	Driver      string  `json:"driver,omitempty"`
	Module      string  `json:"module,omitempty"`
	ModuleKnown bool    `json:"moduleKnown,omitempty"`
	PCIClass    *uint32 `json:"pciClass,omitempty"`
	OutOfTree   bool    `json:"outOfTree,omitempty"`
}

type HostModule struct {
	OutOfTree       bool     `json:"outOfTree"`
	FirmwarePresent []string `json:"firmwarePresent,omitempty"`
}

type HostHardware struct {
	Devices         []HostDevice          `json:"devices"`
	Modules         map[string]HostModule `json:"modules,omitempty"`
	CPUVendor       string                `json:"cpuVendor,omitempty"`
	HasCPUMicrocode bool                  `json:"hasCpuMicrocode,omitempty"`
	Complete        bool                  `json:"complete"`
	IncompleteWhy   string                `json:"incompleteWhy,omitempty"`
}

func normalizeModule(name string) string {
	return strings.ReplaceAll(strings.TrimSpace(name), "-", "_")
}

func moduleNameFromPath(path string) (string, bool) {
	base := path
	if slash := strings.LastIndexByte(base, '/'); slash >= 0 {
		base = base[slash+1:]
	}
	for _, suffix := range []string{".ko.xz", ".ko.zst", ".ko.gz", ".ko"} {
		if stem, ok := strings.CutSuffix(strings.TrimSpace(base), suffix); ok && stem != "" {
			return normalizeModule(stem), true
		}
	}
	return "", false
}

func normalizeFirmware(name string) string {
	name = strings.TrimSpace(name)
	name = strings.TrimPrefix(name, "./")
	name = strings.TrimLeft(name, "/")
	for _, suffix := range []string{".xz", ".zst", ".gz"} {
		if stem, ok := strings.CutSuffix(name, suffix); ok {
			return stem
		}
	}
	return name
}

func parseModuleList(content string) map[string]struct{} {
	modules := make(map[string]struct{})
	for _, line := range strings.Split(content, "\n") {
		path, _, _ := strings.Cut(line, ":")
		if module, ok := moduleNameFromPath(path); ok {
			modules[module] = struct{}{}
		}
	}
	return modules
}

func parseModuleAliases(content string) []moduleAlias {
	var aliases []moduleAlias
	for _, line := range strings.Split(content, "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && fields[0] == "alias" {
			aliases = append(aliases, moduleAlias{Pattern: fields[1], Module: normalizeModule(fields[2])})
		}
	}
	return aliases
}

// parseBuiltinModinfo reads the NUL-separated modules.builtin.modinfo format.
// Entries use <module>.alias=<pattern>; accept :alias too for older generators.
func parseBuiltinModinfo(content string) []moduleAlias {
	var aliases []moduleAlias
	for _, record := range strings.FieldsFunc(content, func(character rune) bool {
		return character == 0 || character == '\n'
	}) {
		key, pattern, ok := strings.Cut(record, "=")
		if !ok || pattern == "" {
			continue
		}
		module, alias := strings.CutSuffix(key, ".alias")
		if !alias {
			module, alias = strings.CutSuffix(key, ":alias")
		}
		if alias && module != "" {
			aliases = append(aliases, moduleAlias{Pattern: pattern, Module: normalizeModule(module)})
		}
	}
	return aliases
}

// globMatch implements the *, ?, [...], [!...] syntax used by kernel aliases
// and module firmware declarations. It deliberately does not use path.Match:
// modaliases are not paths, and malformed classes are matched literally.
func globMatch(pattern, text string) bool {
	p, t := []rune(pattern), []rune(text)
	pi, ti := 0, 0
	starPattern, starText := -1, -1
	for ti < len(t) {
		if pi < len(p) {
			switch p[pi] {
			case '*':
				starPattern, starText = pi+1, ti
				pi++
				continue
			case '?':
				pi++
				ti++
				continue
			case '[':
				matched, width, ok := globClassMatch(p[pi:], t[ti])
				if ok && matched {
					pi += width
					ti++
					continue
				}
				if !ok && p[pi] == t[ti] {
					pi++
					ti++
					continue
				}
			default:
				if p[pi] == t[ti] {
					pi++
					ti++
					continue
				}
			}
		}
		if starPattern < 0 {
			return false
		}
		starText++
		pi, ti = starPattern, starText
	}
	for pi < len(p) && p[pi] == '*' {
		pi++
	}
	return pi == len(p)
}

func globClassMatch(pattern []rune, character rune) (matched bool, width int, ok bool) {
	index := 1
	negate := index < len(pattern) && (pattern[index] == '!' || pattern[index] == '^')
	if negate {
		index++
	}
	first := true
	for index < len(pattern) {
		if pattern[index] == ']' && !first {
			return matched != negate, index + 1, true
		}
		if index+2 < len(pattern) && pattern[index+1] == '-' && pattern[index+2] != ']' {
			if pattern[index] <= character && character <= pattern[index+2] {
				matched = true
			}
			index += 3
		} else {
			if pattern[index] == character {
				matched = true
			}
			index++
		}
		first = false
	}
	return false, 0, false
}

func pciKind(class uint32) (string, bool) {
	switch class >> 16 {
	case 0x01:
		return "storage controller", true
	case 0x02:
		return "network controller", true
	case 0x03:
		return "display controller", true
	case 0x04:
		return "multimedia device", false
	case 0x0c:
		if (class>>8)&0xff == 0x03 {
			return "USB controller", true
		}
		return "serial bus controller", false
	case 0x0d:
		return "wireless controller", true
	case 0x06:
		return "bridge", false
	case 0x08:
		return "system peripheral", false
	case 0x11:
		return "signal processing controller", false
	default:
		return "device", false
	}
}

var firmwareFramebufferDrivers = []string{"simpledrm", "efifb", "simplefb", "vesafb", "ofdrm"}

func driverFirmwarePatterns(module string) []string {
	module = normalizeModule(module)
	switch {
	case module == "iwlwifi":
		return []string{"iwlwifi-*.ucode", "intel/iwlwifi/*"}
	case module == "brcmfmac":
		return []string{"brcm/brcmfmac*"}
	case module == "ath10k_pci" || module == "ath10k_core":
		return []string{"ath10k/*"}
	case module == "ath11k_pci" || module == "ath11k_core":
		return []string{"ath11k/*"}
	case module == "ath12k_pci":
		return []string{"ath12k/*"}
	case strings.HasPrefix(module, "rtw88_"):
		return []string{"rtw88/*"}
	case strings.HasPrefix(module, "rtw89_"):
		return []string{"rtw89/*"}
	default:
		return nil
	}
}

// allKnownDriverFirmwareMissing is intentionally conservative. It reports a
// definite gap only when every alias-matched driver belongs to a kernel family
// with a stable firmware namespace and none of those namespaces exists.
func allKnownDriverFirmwareMissing(drivers []string, target TargetKernel) ([]string, bool) {
	if len(drivers) == 0 {
		return nil, false
	}
	for _, driver := range drivers {
		patterns := driverFirmwarePatterns(driver)
		if len(patterns) == 0 {
			return nil, false
		}
		for _, pattern := range patterns {
			if target.hasFirmware(pattern) {
				return nil, false
			}
		}
	}
	return drivers, true
}

func assessHardware(host HostHardware, target TargetKernel) HardwareReport {
	report := HardwareReport{TargetKernel: target.KVersion}
	var framebuffer []string
	for _, driver := range firmwareFramebufferDrivers {
		if target.hasModule(driver) {
			framebuffer = append(framebuffer, driver)
		}
	}

	type lostKey struct {
		Module   string
		Fallback string
		FBOnly   bool
		Severity HardwareSeverity
	}
	type lostValue struct {
		Devices []string
	}
	lost := make(map[lostKey]lostValue)
	for _, device := range host.Devices {
		if device.Modalias == "" || (device.ModuleKnown && device.Module == "") {
			continue
		}
		report.DevicesChecked++
		module := normalizeModule(device.Module)
		if module != "" && target.hasModule(module) {
			continue
		}
		fallback := target.aliasDrivers(device.Modalias)
		kind, severe := "device", false
		display := false
		if device.PCIClass != nil {
			kind, severe = pciKind(*device.PCIClass)
			display = *device.PCIClass>>16 == 0x03
		}
		// Windows exposes the current Windows driver, not whether Linux binds a
		// loadable module. An unclaimed non-critical chipset function is not
		// evidence of loss; bootc-migrate would omit built-in/driverless devices.
		if module == "" && len(fallback) == 0 && !severe {
			continue
		}
		// Windows cannot run modinfo for the current Linux module. For driver
		// families with stable upstream firmware namespaces, an alias match
		// plus no matching target firmware is still decisive: every supported
		// device in that family needs at least one file in that namespace.
		if module == "" && len(fallback) > 0 {
			if drivers, missing := allKnownDriverFirmwareMissing(fallback, target); missing {
				severity := HardwareWarning
				if severe {
					severity = HardwareBlocking
				}
				report.Findings = append(report.Findings, HardwareFinding{
					Severity: severity,
					Subject:  fmt.Sprintf("%s %s (%s) firmware", strings.ToUpper(device.Bus), device.ID, kind),
					Detail:   fmt.Sprintf("the target kernel claims this hardware with %s, but the image ships none of that driver family's firmware. It is expected to stop working after restart.", strings.Join(drivers, "/")),
				})
			}
			continue
		}
		outOfTree := device.OutOfTree
		if info, ok := host.Modules[module]; ok {
			outOfTree = outOfTree || info.OutOfTree
		}
		fbOnly := len(fallback) == 0 && display && len(framebuffer) > 0
		if fbOnly {
			fallback = append([]string(nil), framebuffer...)
		}
		severity := HardwareNote
		switch {
		case fbOnly:
			severity = HardwareWarning
		case len(fallback) == 0 && (severe || outOfTree):
			severity = HardwareBlocking
		case len(fallback) == 0:
			severity = HardwareWarning
		case outOfTree:
			severity = HardwareWarning
		}
		keyModule := module
		if keyModule == "" {
			keyModule = "no matching target driver"
		}
		key := lostKey{Module: keyModule, Fallback: strings.Join(fallback, ","), FBOnly: fbOnly, Severity: severity}
		value := lost[key]
		value.Devices = append(value.Devices, fmt.Sprintf("%s %s (%s)", strings.ToUpper(device.Bus), device.ID, kind))
		lost[key] = value
	}

	for key, value := range lost {
		fallback := strings.Split(key.Fallback, ",")
		if key.Fallback == "" {
			fallback = nil
		}
		var detail string
		switch {
		case key.FBOnly:
			detail = fmt.Sprintf("no target driver supports this display controller. After restart it can use the firmware framebuffer (%s), without graphics acceleration and usually with one display at the firmware's resolution.", strings.Join(fallback, "/"))
		case key.Module == "no matching target driver":
			detail = fmt.Sprintf("no module in target kernel %s claims this hardware. It is expected to stop working after restart.", target.KVersion)
		case len(fallback) == 0:
			detail = fmt.Sprintf("uses driver %s, which target kernel %s does not ship, and no target driver claims this hardware. It is expected to stop working after restart.", key.Module, target.KVersion)
		case key.Module == "nvidia":
			detail = fmt.Sprintf("uses the proprietary NVIDIA driver, which the target does not ship. %s takes over after restart, without CUDA or the proprietary OpenGL/Vulkan stack and its performance.", strings.Join(fallback, "/"))
		default:
			detail = fmt.Sprintf("uses driver %s, which the target does not ship; %s supports the hardware after restart.", key.Module, strings.Join(fallback, "/"))
		}
		report.Findings = append(report.Findings, HardwareFinding{Severity: key.Severity, Subject: summarizeDevices(value.Devices), Detail: detail})
	}

	for module, info := range host.Modules {
		if len(info.FirmwarePresent) == 0 || !target.hasModule(module) {
			continue
		}
		var absent []string
		for _, firmware := range info.FirmwarePresent {
			if !target.hasFirmware(firmware) {
				absent = append(absent, firmware)
			}
		}
		if len(absent) == 0 {
			continue
		}
		severe := false
		for _, device := range host.Devices {
			if normalizeModule(device.Module) != normalizeModule(module) || device.PCIClass == nil {
				continue
			}
			_, important := pciKind(*device.PCIClass)
			displayWithFallback := *device.PCIClass>>16 == 0x03 && len(framebuffer) > 0
			severe = severe || (important && !displayWithFallback)
		}
		if len(absent) == len(info.FirmwarePresent) {
			severity := HardwareWarning
			if severe {
				severity = HardwareBlocking
			}
			report.Findings = append(report.Findings, HardwareFinding{Severity: severity, Subject: fmt.Sprintf("driver %s firmware", module), Detail: fmt.Sprintf("the target image ships none of the %d firmware files available for this device (%s). Hardware that needs firmware to start is expected to stop working after restart.", len(absent), sampleFirmware(absent))})
		} else {
			report.Findings = append(report.Findings, HardwareFinding{Severity: HardwareNote, Subject: fmt.Sprintf("driver %s firmware", module), Detail: fmt.Sprintf("the target image lacks %d of %d firmware variants (%s); the missing files are likely for other models.", len(absent), len(info.FirmwarePresent), sampleFirmware(absent))})
		}
	}

	microcodeDir := ""
	switch host.CPUVendor {
	case "GenuineIntel":
		microcodeDir = "intel-ucode/"
	case "AuthenticAMD":
		microcodeDir = "amd-ucode/"
	}
	if microcodeDir != "" && host.HasCPUMicrocode {
		found := false
		for firmware := range target.Firmware {
			if strings.HasPrefix(firmware, microcodeDir) {
				found = true
				break
			}
		}
		if !found {
			report.Findings = append(report.Findings, HardwareFinding{Severity: HardwareWarning, Subject: "CPU microcode (" + host.CPUVendor + ")", Detail: "the target image has no CPU microcode updates; the CPU will rely on the firmware-loaded revision without the image's security and stability fixes."})
		}
	}

	if target.LayersSkipped > 0 || !host.Complete {
		for index := range report.Findings {
			if report.Findings[index].Severity == HardwareBlocking {
				report.Findings[index].Severity = HardwareWarning
			}
		}
		var reasons []string
		if target.LayersSkipped > 0 {
			reasons = append(reasons, fmt.Sprintf("%d target image layer(s) could not be read", target.LayersSkipped))
		}
		if !host.Complete {
			reason := host.IncompleteWhy
			if reason == "" {
				reason = "the Windows device inventory could not be read completely"
			}
			reasons = append(reasons, reason)
		}
		report.Findings = append(report.Findings, HardwareFinding{Severity: HardwareWarning, Subject: "incomplete hardware check", Detail: strings.Join(reasons, "; ") + ". Missing items are not proof of incompatibility, so this check does not block installation."})
	}

	sort.Slice(report.Findings, func(i, j int) bool {
		left, right := report.Findings[i], report.Findings[j]
		if severityRank(left.Severity) != severityRank(right.Severity) {
			return severityRank(left.Severity) > severityRank(right.Severity)
		}
		if left.Subject != right.Subject {
			return left.Subject < right.Subject
		}
		return left.Detail < right.Detail
	})
	return report
}

func severityRank(severity HardwareSeverity) int {
	switch severity {
	case HardwareBlocking:
		return 3
	case HardwareWarning:
		return 2
	case HardwareNote:
		return 1
	default:
		return 0
	}
}

func summarizeDevices(devices []string) string {
	sort.Strings(devices)
	limit := len(devices)
	if limit > 4 {
		limit = 4
	}
	summary := strings.Join(devices[:limit], ", ")
	if len(devices) > limit {
		summary += fmt.Sprintf(", and %d more", len(devices)-limit)
	}
	return summary
}

func sampleFirmware(names []string) string {
	limit := len(names)
	if limit > 4 {
		limit = 4
	}
	sample := strings.Join(names[:limit], ", ")
	if len(names) > limit {
		sample += fmt.Sprintf(" and %d more", len(names)-limit)
	}
	return sample
}
