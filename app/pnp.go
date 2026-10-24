package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

type pnpRecord struct {
	PNPDeviceID            string   `json:"pnpDeviceId"`
	HardwareIDs            []string `json:"hardwareIds"`
	CompatibleIDs          []string `json:"compatibleIds"`
	Service                string   `json:"service"`
	Name                   string   `json:"name"`
	PNPClass               string   `json:"pnpClass"`
	Manufacturer           string   `json:"manufacturer"`
	Status                 string   `json:"status"`
	ConfigManagerErrorCode uint32   `json:"configManagerErrorCode"`
}

var (
	pciDeviceIDPattern  = regexp.MustCompile(`(?i)^PCI\\VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})(?:&SUBSYS_([0-9A-F]{8}))?`)
	pciClassPattern     = regexp.MustCompile(`(?i)(?:^|[&\\])CC_([0-9A-F]{4})([0-9A-F]{2})?(?:&|\\|$)`)
	usbDeviceIDPattern  = regexp.MustCompile(`(?i)^USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})(?:&REV_([0-9A-F]{4}))?`)
	usbClassPattern     = regexp.MustCompile(`(?i)^USB\\CLASS_([0-9A-F]{2})(?:&SUBCLASS_([0-9A-F]{2}))?(?:&PROT_([0-9A-F]{2}))?`)
	usbInterfacePattern = regexp.MustCompile(`(?i)(?:^|&)MI_([0-9A-F]{2})(?:&|\\|$)`)
)

func hostHardwareFromPnP(records []pnpRecord, complete bool, incompleteWhy string) HostHardware {
	host := HostHardware{Modules: make(map[string]HostModule), Complete: complete, IncompleteWhy: incompleteWhy}
	seen := make(map[string]struct{})
	for _, record := range records {
		if record.ConfigManagerErrorCode != 0 || (record.Status != "" && !strings.EqualFold(record.Status, "OK")) {
			continue
		}
		device, ok := pnpDeviceToHost(record)
		if !ok {
			continue
		}
		key := device.Bus + "\x00" + device.Modalias
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		host.Devices = append(host.Devices, device)
		if device.Module != "" {
			host.Modules[normalizeModule(device.Module)] = HostModule{OutOfTree: device.OutOfTree}
		}
	}
	return host
}

func pnpDeviceToHost(record pnpRecord) (HostDevice, bool) {
	ids := make([]string, 0, 1+len(record.HardwareIDs)+len(record.CompatibleIDs))
	ids = append(ids, record.PNPDeviceID)
	ids = append(ids, record.HardwareIDs...)
	ids = append(ids, record.CompatibleIDs...)
	for _, id := range ids {
		if match := pciDeviceIDPattern.FindStringSubmatch(strings.TrimSpace(id)); match != nil {
			return pciHostDevice(record, ids, match)
		}
	}
	for _, id := range ids {
		if match := usbDeviceIDPattern.FindStringSubmatch(strings.TrimSpace(id)); match != nil {
			return usbHostDevice(record, ids, match)
		}
	}
	return HostDevice{}, false
}

func pciHostDevice(record pnpRecord, ids []string, match []string) (HostDevice, bool) {
	classHex := ""
	interfaceHex := "00"
	for _, id := range ids {
		if classMatch := pciClassPattern.FindStringSubmatch(strings.TrimSpace(id)); classMatch != nil {
			classHex = strings.ToUpper(classMatch[1])
			if classMatch[2] != "" {
				interfaceHex = strings.ToUpper(classMatch[2])
			}
			break
		}
	}
	if classHex == "" {
		classHex = pciClassFromPnPClass(record.PNPClass)
	}
	if len(classHex) != 4 {
		return HostDevice{}, false
	}
	classValue, err := strconv.ParseUint(classHex+interfaceHex, 16, 32)
	if err != nil {
		return HostDevice{}, false
	}
	vendor, device := strings.ToUpper(match[1]), strings.ToUpper(match[2])
	subVendor, subDevice := "0000", "0000"
	if len(match) > 3 && match[3] != "" {
		subsystem := strings.ToUpper(match[3])
		// Windows SUBSYS is device then vendor; Linux modalias is vendor then device.
		subDevice, subVendor = subsystem[:4], subsystem[4:]
	}
	class := uint32(classValue)
	module, outOfTree := windowsModuleHint(record, class>>16 == 0x03)
	label := record.Name
	if label == "" {
		label = record.PNPDeviceID
	}
	return HostDevice{
		Bus: "pci", ID: label,
		Modalias: fmt.Sprintf("pci:v0000%sd0000%ssv0000%ssd0000%sbc%ssc%si%s", vendor, device, subVendor, subDevice, classHex[:2], classHex[2:], interfaceHex),
		Driver:   record.Service, Module: module, ModuleKnown: module != "", PCIClass: &class, OutOfTree: outOfTree,
	}, true
}

func usbHostDevice(record pnpRecord, ids []string, match []string) (HostDevice, bool) {
	vendor, product := strings.ToUpper(match[1]), strings.ToUpper(match[2])
	revision := "0000"
	for _, id := range ids {
		if strings.EqualFold(strings.TrimSpace(id), `USB\COMPOSITE`) {
			return HostDevice{}, false
		}
		if revisionMatch := usbDeviceIDPattern.FindStringSubmatch(strings.TrimSpace(id)); revisionMatch != nil && len(revisionMatch) > 3 && revisionMatch[3] != "" {
			revision = strings.ToUpper(revisionMatch[3])
		}
	}
	deviceClass, deviceSubclass, deviceProtocol := "00", "00", "00"
	interfaceClass, interfaceSubclass, interfaceProtocol := "00", "00", "00"
	interfaceNumber := "00"
	composite := false
	for _, id := range ids {
		if interfaceMatch := usbInterfacePattern.FindStringSubmatch(strings.TrimSpace(id)); interfaceMatch != nil {
			interfaceNumber = strings.ToUpper(interfaceMatch[1])
			composite = true
		}
	}
	for _, id := range ids {
		if classMatch := usbClassPattern.FindStringSubmatch(strings.TrimSpace(id)); classMatch != nil {
			class, subclass, protocol := strings.ToUpper(classMatch[1]), "00", "00"
			if classMatch[2] != "" {
				subclass = strings.ToUpper(classMatch[2])
			}
			if classMatch[3] != "" {
				protocol = strings.ToUpper(classMatch[3])
			}
			if class == "09" {
				return HostDevice{}, false // hubs are driven by built-in usbcore
			}
			interfaceClass, interfaceSubclass, interfaceProtocol = class, subclass, protocol
			if !composite {
				deviceClass, deviceSubclass, deviceProtocol = class, subclass, protocol
			}
			break
		}
	}
	module, outOfTree := windowsModuleHint(record, false)
	label := record.Name
	if label == "" {
		label = record.PNPDeviceID
	}
	return HostDevice{
		Bus: "usb", ID: label,
		Modalias: fmt.Sprintf("usb:v%sp%sd%sdc%sdsc%sdp%sic%sisc%sip%sin%s", vendor, product, revision, deviceClass, deviceSubclass, deviceProtocol, interfaceClass, interfaceSubclass, interfaceProtocol, interfaceNumber),
		Driver:   record.Service, Module: module, ModuleKnown: module != "", OutOfTree: outOfTree,
	}, true
}

func pciClassFromPnPClass(class string) string {
	switch strings.ToLower(strings.TrimSpace(class)) {
	case "scsiadapter", "hdc":
		return "0100"
	case "net":
		return "0200"
	case "display":
		return "0300"
	case "media":
		return "0400"
	case "usb":
		return "0C03"
	default:
		return ""
	}
}

func windowsModuleHint(record pnpRecord, display bool) (module string, outOfTree bool) {
	service := strings.ToLower(record.Service)
	manufacturer := strings.ToLower(record.Manufacturer)
	if strings.Contains(service, "nvlddmkm") || (display && strings.Contains(manufacturer, "nvidia")) {
		return "nvidia", true
	}
	return "", false
}
