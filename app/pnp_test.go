package main

import (
	"strings"
	"testing"
)

func TestPCIIdentifiersBecomeLinuxModalias(t *testing.T) {
	device, ok := pnpDeviceToHost(pnpRecord{
		PNPDeviceID:   `PCI\VEN_8086&DEV_A0F0&SUBSYS_07A11028&REV_20\3&11583659&0&A3`,
		CompatibleIDs: []string{`PCI\CC_028000`, `PCI\CC_0280`},
		Name:          "Intel wireless controller",
		PNPClass:      "Net",
		Status:        "OK",
	})
	if !ok {
		t.Fatal("PCI device was not parsed")
	}
	want := "pci:v00008086d0000A0F0sv00001028sd000007A1bc02sc80i00"
	if device.Modalias != want {
		t.Fatalf("modalias = %q, want %q", device.Modalias, want)
	}
	if device.PCIClass == nil || *device.PCIClass != 0x028000 {
		t.Fatalf("PCI class = %v", device.PCIClass)
	}
}

func TestUSBIdentifiersBecomeLinuxModalias(t *testing.T) {
	device, ok := pnpDeviceToHost(pnpRecord{
		PNPDeviceID:   `USB\VID_0BDA&PID_8179\00E04C000001`,
		HardwareIDs:   []string{`USB\VID_0BDA&PID_8179&REV_0001`, `USB\VID_0BDA&PID_8179`},
		CompatibleIDs: []string{`USB\CLASS_E0&SUBCLASS_01&PROT_01`},
		Name:          "USB wireless adapter",
		Status:        "OK",
	})
	if !ok {
		t.Fatal("USB device was not parsed")
	}
	want := "usb:v0BDAp8179d0001dcE0dsc01dp01icE0isc01ip01in00"
	if device.Modalias != want {
		t.Fatalf("modalias = %q, want %q", device.Modalias, want)
	}
}

func TestCompositeUSBUsesInterfaceFields(t *testing.T) {
	device, ok := pnpDeviceToHost(pnpRecord{
		PNPDeviceID:   `USB\VID_1234&PID_5678&MI_02\7&1`,
		CompatibleIDs: []string{`USB\CLASS_03&SUBCLASS_01&PROT_02`},
	})
	if !ok {
		t.Fatal("composite USB device was not parsed")
	}
	if !strings.HasSuffix(device.Modalias, "dc00dsc00dp00ic03isc01ip02in02") {
		t.Fatalf("composite modalias = %q", device.Modalias)
	}
}

func TestUSBParentsWithoutLoadableDriversAreSkipped(t *testing.T) {
	for _, record := range []pnpRecord{
		{
			PNPDeviceID:   `USB\VID_1234&PID_5678\1`,
			CompatibleIDs: []string{`USB\CLASS_09&SUBCLASS_00&PROT_01`},
		},
		{
			PNPDeviceID:   `USB\VID_1234&PID_5678\2`,
			CompatibleIDs: []string{`USB\COMPOSITE`},
		},
	} {
		if device, ok := pnpDeviceToHost(record); ok {
			t.Fatalf("USB parent was judged: %+v", device)
		}
	}
}

func TestNvidiaWindowsDriverIsOutOfTreeHint(t *testing.T) {
	host := hostHardwareFromPnP([]pnpRecord{{
		PNPDeviceID:   `PCI\VEN_10DE&DEV_2204&SUBSYS_403A1458`,
		CompatibleIDs: []string{`PCI\VEN_10DE&DEV_2204&CC_030000`},
		Service:       "nvlddmkm",
		Manufacturer:  "NVIDIA",
		Status:        "OK",
	}}, true, "")
	if len(host.Devices) != 1 || host.Devices[0].Module != "nvidia" || !host.Devices[0].OutOfTree {
		t.Fatalf("NVIDIA hint absent: %+v", host)
	}
}

func TestNvidiaSiblingFunctionsAreNotGraphicsDriverHints(t *testing.T) {
	device, ok := pnpDeviceToHost(pnpRecord{
		PNPDeviceID:   `PCI\VEN_10DE&DEV_1AEB&SUBSYS_00000000`,
		CompatibleIDs: []string{`PCI\VEN_10DE&DEV_1AEB&CC_040300`},
		Service:       "nvhda",
		Manufacturer:  "NVIDIA",
		Status:        "OK",
	})
	if !ok {
		t.Fatal("NVIDIA audio function was not parsed")
	}
	if device.Module != "" || device.OutOfTree {
		t.Fatalf("NVIDIA audio function was tagged as graphics: %+v", device)
	}
}

func TestPnPInventorySkipsBrokenAndDuplicateRecords(t *testing.T) {
	record := pnpRecord{
		PNPDeviceID:   `PCI\VEN_8086&DEV_A0F0`,
		CompatibleIDs: []string{`PCI\VEN_8086&DEV_A0F0&CC_0280`},
		Status:        "OK",
	}
	broken := record
	broken.ConfigManagerErrorCode = 22
	host := hostHardwareFromPnP([]pnpRecord{record, record, broken, {PNPDeviceID: "ROOT\\UNKNOWN", Status: "OK"}}, true, "")
	if len(host.Devices) != 1 {
		t.Fatalf("devices = %+v", host.Devices)
	}
}
