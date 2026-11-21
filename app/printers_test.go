package main

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func TestPrintersFromRecordedInventory(t *testing.T) {
	out, err := os.ReadFile("testdata/printers/inventory-ps51.txt")
	if err != nil {
		t.Fatal(err)
	}
	m, err := printersFromInventory(out)
	if err != nil {
		t.Fatal(err)
	}
	if m.SchemaVersion != 1 {
		t.Fatalf("schemaVersion = %d, want 1", m.SchemaVersion)
	}
	want := []windowsPrinter{
		{Name: "Office Laser a1b2", PortName: "127.0.0.2", DriverName: "Generic / Text Only", Default: true, PortKind: "tcpip", Host: "127.0.0.2", Port: 9100, Protocol: "raw"},
		{Name: "Lab Printer a1b2", PortName: "IP_192.0.2.44", DriverName: "Generic / Text Only", Shared: true, PortKind: "tcpip", Host: "192.0.2.44", Port: 9100, Protocol: "raw"},
		{Name: "Label Printer a1b2", PortName: "LPT1:", DriverName: "Generic / Text Only", PortKind: "lpt"},
		{Name: "Microsoft Print to PDF", PortName: "PORTPROMPT:", DriverName: "Microsoft Print To PDF", PortKind: "virtual"},
		{Name: "Microsoft XPS Document Writer", PortName: "PORTPROMPT:", DriverName: "Microsoft XPS Document Writer v4", PortKind: "virtual"},
		{Name: "OneNote (Desktop)", PortName: "nul:", DriverName: "Send to Microsoft OneNote 16 Driver", PortKind: "file"},
		{Name: "Fax", PortName: "SHRFAX:", DriverName: "Microsoft Shared Fax Driver", PortKind: "virtual"},
		{Name: "HP OfficeJet (USB)", PortName: "USB001", DriverName: "HP OfficeJet Pro 9010 series PCL-3", PortKind: "usb"},
		{Name: "Brother WSD", PortName: "WSD-3b2c6f0e-4d1a-4a8e-9d55-0d3c0f1f2a3b", DriverName: "Brother HL-L2350DW series", PortKind: "wsd"},
		{Name: "Canon IPP", PortName: "http://192.168.1.50:631/ipp/print", DriverName: "Microsoft IPP Class Driver", PortKind: "ipp", Host: "192.168.1.50", URI: "http://192.168.1.50:631/ipp/print"},
		{Name: "Zebra LPR", PortName: "zebra.lan", DriverName: "ZDesigner GK420d", PortKind: "tcpip", Host: "zebra.lan", Port: 515, Protocol: "lpr", LprQueue: "labels"},
		{Name: "Serial Receipt", PortName: "COM2:", DriverName: "Generic / Text Only", PortKind: "com"},
		{Name: "Plotter File", PortName: "FILE:", DriverName: "HP-GL/2 Plotter", PortKind: "file"},
		{Name: `\\print01\Floor3`, PortName: `\\print01\Floor3`, DriverName: "Xerox Global Print Driver PCL6", PortKind: "other"},
	}
	if !reflect.DeepEqual(m.Printers, want) {
		for i := range want {
			if i >= len(m.Printers) || !reflect.DeepEqual(m.Printers[i], want[i]) {
				var got any
				if i < len(m.Printers) {
					got = m.Printers[i]
				}
				t.Errorf("printer %d:\n got %+v\nwant %+v", i, got, want[i])
			}
		}
		if len(m.Printers) != len(want) {
			t.Errorf("got %d printers, want %d", len(m.Printers), len(want))
		}
	}
}

// The port, not the driver, decides: a "Print to PDF" driver on a network
// port is a real printer, and a real vendor driver on PORTPROMPT: is not.
func TestPrinterKindComesFromThePortNotTheDriver(t *testing.T) {
	out := []byte(`{"printers":[` +
		`{"Name":"PDF on net","PortName":"IP_10.0.0.9","DriverName":"Microsoft Print To PDF"},` +
		`{"Name":"Vendor to file","PortName":"PORTPROMPT:","DriverName":"HP LaserJet 400 PCL6"}],` +
		`"ports":[{"Name":"IP_10.0.0.9","PrinterHostAddress":"10.0.0.9","PortNumber":9100,"Protocol":"RAW"}],"default":null}`)
	m, err := printersFromInventory(out)
	if err != nil {
		t.Fatal(err)
	}
	if got := m.Printers[0]; got.PortKind != "tcpip" || got.Host != "10.0.0.9" || got.Protocol != "raw" || got.Default {
		t.Errorf("PDF driver on a TCP/IP port: %+v", got)
	}
	if got := m.Printers[1]; got.PortKind != "virtual" {
		t.Errorf("vendor driver on PORTPROMPT: = %q, want virtual", got.PortKind)
	}
}

// ConvertTo-Json flattens a one-element collection to the element itself on
// some PowerShell paths; a lone printer must still be read.
func TestPrintersFromInventoryAcceptsALoneObject(t *testing.T) {
	out := []byte(`{"printers":{"Name":"Only","PortName":"USB001"},"ports":{"Name":"USB001"},"default":"only"}`)
	m, err := printersFromInventory(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Printers) != 1 || m.Printers[0].PortKind != "usb" || !m.Printers[0].Default {
		t.Fatalf("lone printer: %+v", m.Printers)
	}
}

func TestPrintersManifestWireFormat(t *testing.T) {
	m, err := printersFromInventory(nil)
	if err != nil {
		t.Fatal(err)
	}
	data, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	// An empty inventory is still a manifest: the importer can tell "no
	// printers" from "the collector never ran".
	if string(data) != `{"schemaVersion":1,"printers":[]}` {
		t.Fatalf("empty manifest = %s", data)
	}
	data, err = json.Marshal(windowsPrinter{Name: "LPT", PortName: "LPT1:", PortKind: "lpt"})
	if err != nil {
		t.Fatal(err)
	}
	// Unknown fields are omitted; default and shared are always present.
	if string(data) != `{"name":"LPT","portName":"LPT1:","default":false,"shared":false,"portKind":"lpt"}` {
		t.Fatalf("printer wire format = %s", data)
	}
}

func TestPrintersFromInventoryRejectsGarbage(t *testing.T) {
	if _, err := printersFromInventory([]byte("Get-Printer : The spooler service is not reachable.")); err == nil {
		t.Fatal("non-JSON output must be an error, not an empty manifest")
	}
}
