package main

import (
	"fmt"
	"strconv"
	"strings"
)

type hardwarePnPDevice struct {
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	HardwareIDs   []string `json:"hardwareIds"`
	CompatibleIDs []string `json:"compatibleIds"`
	Service       string   `json:"service"`
}

func hardwareIDField(ids []string, key string, length int) string {
	for _, id := range ids {
		id = strings.ToUpper(id)
		for _, field := range strings.FieldsFunc(id, func(r rune) bool { return r == '\\' || r == '&' }) {
			if !strings.HasPrefix(field, key) {
				continue
			}
			value := strings.TrimPrefix(field, key)
			if len(value) != length {
				continue
			}
			if _, err := strconv.ParseUint(value, 16, 32); err == nil {
				return value
			}
		}
	}
	return ""
}

func hardwareFromPnP(p hardwarePnPDevice) hardwareDevice {
	d := hardwareDevice{ID: p.ID, Uncertain: true}
	if p.Name != "" {
		d.ID = p.Name + " (" + p.ID + ")"
	}
	ids := append(append([]string{}, p.HardwareIDs...), p.CompatibleIDs...)
	if strings.HasPrefix(strings.ToUpper(p.ID), `PCI\`) {
		vendor, device := hardwareIDField(ids, "VEN_", 4), hardwareIDField(ids, "DEV_", 4)
		sub := hardwareIDField(ids, "SUBSYS_", 8)
		class := hardwareIDField(ids, "CC_", 6)
		if class == "" {
			if short := hardwareIDField(ids, "CC_", 4); short != "" {
				class = short + "00"
			}
		}
		if class != "" {
			value, _ := strconv.ParseUint(class, 16, 32)
			d.Class = uint32(value)
		}
		d.NVIDIA = vendor == "10DE" && strings.Contains(strings.ToLower(p.Service), "nv")
		if vendor != "" && device != "" && sub != "" && class != "" {
			d.Modalias = fmt.Sprintf("pci:v0000%sd0000%ssv0000%ssd0000%sbc%ssc%si%s", vendor, device, sub[4:], sub[:4], class[:2], class[2:4], class[4:])
			d.Uncertain = false
		}
	} else if strings.HasPrefix(strings.ToUpper(p.ID), `USB\`) {
		vendor, product := hardwareIDField(ids, "VID_", 4), hardwareIDField(ids, "PID_", 4)
		revision := hardwareIDField(ids, "REV_", 4)
		class, subclass, protocol := hardwareIDField(ids, "CLASS_", 2), hardwareIDField(ids, "SUBCLASS_", 2), hardwareIDField(ids, "PROT_", 2)
		// PnP class IDs describe either a device or an interface, not both.
		// Do not manufacture dc/ic values: retain the known prefix for diagnostics
		// but leave the assessment unknown until a full USB descriptor is available.
		if vendor != "" && product != "" {
			d.Modalias = "usb:v" + vendor + "p" + product
		}
		if revision != "" {
			d.Modalias += "d" + revision
		}
		if class != "" {
			d.Modalias += " class=" + class + subclass + protocol
		}
	}
	return d
}
