package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
)

// Printer migration (SPEC §4.6, "Printers/scanners"). Phase 1 records every
// Windows printer and how it is connected; the Linux importer
// (payload/migration/wootc-printer-import) turns the network ones into
// driverless IPP Everywhere queues and reports the rest honestly. Windows
// drivers are never copied: they cannot run on Linux.
//
// This file is the portable half — PowerShell output in, printers.json out —
// so the classification is unit-tested on Linux with recorded PowerShell
// JSON. Collection itself (collectPrinters) is Windows-only.

// printerPortKind values: the importer keys its behaviour on these strings.
const (
	printerPortTCPIP   = "tcpip"   // Standard TCP/IP port (RAW 9100 or LPR)
	printerPortIPP     = "ipp"     // the port name is an http/https/ipp/ipps URL
	printerPortWSD     = "wsd"     // Web Services for Devices discovery port
	printerPortUSB     = "usb"     // USB001, DOT4_001 (HP over USB)
	printerPortLPT     = "lpt"     // parallel cable
	printerPortCOM     = "com"     // serial cable
	printerPortFile    = "file"    // FILE:, nul:
	printerPortVirtual = "virtual" // Print to PDF, XPS, OneNote, Fax
	printerPortOther   = "other"
)

// printersManifest is <storage root>\wootc\install\printers.json.
type printersManifest struct {
	SchemaVersion int              `json:"schemaVersion"`
	Printers      []windowsPrinter `json:"printers"`
}

type windowsPrinter struct {
	Name       string `json:"name"`
	PortName   string `json:"portName,omitempty"`
	DriverName string `json:"driverName,omitempty"`
	Default    bool   `json:"default"`
	Shared     bool   `json:"shared"`
	PortKind   string `json:"portKind"`
	Host       string `json:"host,omitempty"`
	Port       int    `json:"port,omitempty"`
	Protocol   string `json:"protocol,omitempty"`
	LprQueue   string `json:"lprQueue,omitempty"`
	URI        string `json:"uri,omitempty"`
}

// printerInventoryScript prints one JSON object: the printers, the ports and
// the default printer's name. Selecting a property a port class lacks (a WSD
// port has no PrinterHostAddress) yields null, which the parser tolerates.
const printerInventoryScript = `$ErrorActionPreference = 'SilentlyContinue'
$printers = @(Get-Printer | Select-Object Name, PortName, DriverName, Shared, Type)
$ports = @(Get-PrinterPort | Select-Object Name, PrinterHostAddress, PortNumber, Protocol, LprQueueName, Description, PortMonitor)
$default = (Get-CimInstance Win32_Printer -Filter 'Default=TRUE' | Select-Object -First 1).Name
[pscustomobject]@{ printers = $printers; ports = $ports; default = $default } | ConvertTo-Json -Depth 4 -Compress`

type psPrinter struct {
	Name       string `json:"Name"`
	PortName   string `json:"PortName"`
	DriverName string `json:"DriverName"`
	Shared     bool   `json:"Shared"`
}

type psPrinterPort struct {
	Name               string `json:"Name"`
	PrinterHostAddress string `json:"PrinterHostAddress"`
	PortNumber         int    `json:"PortNumber"`
	// Protocol is 1 (RAW) or 2 (LPR) on Windows PowerShell 5.1; PowerShell 7
	// can render the same enum as "RAW"/"LPR". Kept raw and read by name.
	Protocol     json.RawMessage `json:"Protocol"`
	LprQueueName string          `json:"LprQueueName"`
	Description  string          `json:"Description"`
	PortMonitor  string          `json:"PortMonitor"`
}

// psList accepts both a JSON array and a lone object: ConvertTo-Json flattens
// a one-element collection to its element in some PowerShell paths.
type psList[T any] []T

func (l *psList[T]) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || bytes.Equal(data, []byte("null")) {
		*l = nil
		return nil
	}
	if data[0] == '[' {
		var items []T
		if err := json.Unmarshal(data, &items); err != nil {
			return err
		}
		*l = items
		return nil
	}
	var one T
	if err := json.Unmarshal(data, &one); err != nil {
		return err
	}
	*l = []T{one}
	return nil
}

type psPrinterInventory struct {
	Printers psList[psPrinter]     `json:"printers"`
	Ports    psList[psPrinterPort] `json:"ports"`
	Default  string                `json:"default"`
}

// printersFromInventory turns printerInventoryScript's output into the
// manifest the Linux importer reads.
func printersFromInventory(out []byte) (printersManifest, error) {
	m := printersManifest{SchemaVersion: 1, Printers: []windowsPrinter{}}
	// runPowerShellOutput returns stderr too; the compressed JSON is the
	// last line that opens an object, whatever a module printed before it.
	var doc []byte
	for _, line := range bytes.Split(out, []byte("\n")) {
		if line = bytes.TrimSpace(line); len(line) > 0 && line[0] == '{' {
			doc = line
		}
	}
	if doc == nil {
		if len(bytes.TrimSpace(out)) == 0 {
			return m, nil
		}
		return m, fmt.Errorf("printer inventory printed no JSON: %.200s", out)
	}
	var inv psPrinterInventory
	if err := json.Unmarshal(doc, &inv); err != nil {
		return m, fmt.Errorf("printer inventory is not JSON: %w", err)
	}
	ports := make(map[string]psPrinterPort, len(inv.Ports))
	for _, p := range inv.Ports {
		ports[strings.ToLower(p.Name)] = p
	}
	for _, p := range inv.Printers {
		if strings.TrimSpace(p.Name) == "" {
			continue
		}
		wp := windowsPrinter{
			Name:       p.Name,
			PortName:   p.PortName,
			DriverName: p.DriverName,
			Default:    inv.Default != "" && strings.EqualFold(p.Name, inv.Default),
			Shared:     p.Shared,
		}
		port, known := ports[strings.ToLower(p.PortName)]
		classifyPrinterPort(&wp, port, known)
		m.Printers = append(m.Printers, wp)
	}
	return m, nil
}

// classifyPrinterPort decides how the printer is connected from its PORT,
// never its driver: a vendor driver can sit on any port, while the port alone
// says whether Linux could reach the device over the network.
func classifyPrinterPort(wp *windowsPrinter, port psPrinterPort, known bool) {
	name := strings.TrimSpace(wp.PortName)
	lower := strings.ToLower(name)

	if u, err := url.Parse(name); err == nil && u.Host != "" {
		switch strings.ToLower(u.Scheme) {
		case "http", "https", "ipp", "ipps":
			wp.PortKind = printerPortIPP
			wp.URI = name
			wp.Host = u.Hostname()
			return
		}
	}
	if known && strings.TrimSpace(port.PrinterHostAddress) != "" {
		wp.PortKind = printerPortTCPIP
		wp.Host = strings.TrimSpace(port.PrinterHostAddress)
		wp.Port = port.PortNumber
		switch printerProtocol(port.Protocol) {
		case 1:
			wp.Protocol = "raw"
		case 2:
			wp.Protocol = "lpr"
			wp.LprQueue = port.LprQueueName
		}
		return
	}
	switch {
	case strings.HasPrefix(lower, "wsd-") || strings.EqualFold(port.PortMonitor, "WSD Port"):
		wp.PortKind = printerPortWSD
	case strings.HasPrefix(lower, "usb") || strings.HasPrefix(lower, "dot4"):
		wp.PortKind = printerPortUSB
	case strings.HasPrefix(lower, "lpt"):
		wp.PortKind = printerPortLPT
	case strings.HasPrefix(lower, "com") && len(lower) > 3 && lower[3] >= '0' && lower[3] <= '9':
		wp.PortKind = printerPortCOM
	case lower == "file:" || lower == "nul:" || lower == "nul":
		wp.PortKind = printerPortFile
	case lower == "portprompt:" || lower == "xpsport:" || lower == "shrfax:" ||
		strings.Contains(lower, "onenote") || strings.Contains(lower, "pdf") ||
		strings.Contains(lower, "xps") || strings.Contains(lower, "fax"):
		wp.PortKind = printerPortVirtual
	default:
		wp.PortKind = printerPortOther
	}
}

// printerProtocol reads MSFT_TcpIpPrinterPort.Protocol in either rendering.
func printerProtocol(raw json.RawMessage) int {
	var n int
	if json.Unmarshal(raw, &n) == nil {
		return n
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		switch strings.ToUpper(strings.TrimSpace(s)) {
		case "RAW", "1":
			return 1
		case "LPR", "2":
			return 2
		}
	}
	return 0
}
