package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const (
	testWootcGUID   = "{11111111-2222-3333-4444-555555555555}"
	testForeignGUID = "{aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}"
)

// firmwareDump renders a `bcdedit /enum firmware` dump in the shape Windows
// prints it: titled objects, dashed underlines, multi-line list values.
func firmwareDump(displayOrder, bootSequence []string, extra ...string) string {
	var b strings.Builder
	b.WriteString("\r\nFirmware Boot Manager\r\n---------------------\r\nidentifier              {fwbootmgr}\r\n")
	list := func(key string, ids []string) {
		for i, id := range ids {
			if i == 0 {
				b.WriteString(key + strings.Repeat(" ", 24-len(key)) + id + "\r\n")
			} else {
				b.WriteString(strings.Repeat(" ", 24) + id + "\r\n")
			}
		}
	}
	list("displayorder", displayOrder)
	list("bootsequence", bootSequence)
	b.WriteString("timeout                 0\r\n\r\n")
	b.WriteString("Windows Boot Manager\r\n--------------------\r\nidentifier              {bootmgr}\r\ndevice                  partition=\\Device\\HarddiskVolume1\r\npath                    \\EFI\\Microsoft\\Boot\\bootmgfw.efi\r\ndescription             Windows Boot Manager\r\n\r\n")
	for _, e := range extra {
		b.WriteString(e)
	}
	return b.String()
}

func firmwareApp(id, desc, path string) string {
	return "Firmware Application (101fffff)\r\n-------------------------------\r\nidentifier              " + id +
		"\r\ndevice                  partition=\\Device\\HarddiskVolume1\r\npath                    " + path +
		"\r\ndescription             " + desc + "\r\n\r\n"
}

var wootcApp = firmwareApp(testWootcGUID, "wootc", `\EFI\fedora\shimx64.efi`)

func armedObservation(fw string) BootObservation {
	files := []string{"efi/fedora/shimx64.efi", "efi/wootc/deployer-vmlinuz"}
	return BootObservation{
		FirmwareEnum: fw,
		ArmedPresent: true,
		Armed: ArmedState{
			BcdGuid:       testWootcGUID,
			EspFiles:      files,
			EspFileHashes: map[string]string{files[0]: "aa", files[1]: "bb"},
		},
		RecordedGUID:     testWootcGUID,
		ESPFound:         true,
		OwnedESPFiles:    files,
		CurrentHashes:    map[string]string{files[0]: "aa", files[1]: "bb"},
		LifecyclePresent: true,
		Lifecycle:        LifecycleState{State: StateFailed},
		DeployerStarted:  true,
	}
}

func TestParseBCDEntriesReadsMultiLineLists(t *testing.T) {
	entries := parseBCDEntries(firmwareDump([]string{"{bootmgr}", testWootcGUID}, []string{testWootcGUID}, wootcApp))
	if len(entries) != 3 {
		t.Fatalf("got %d entries, want 3: %+v", len(entries), entries)
	}
	fw := entries[0]
	if fw.ID != "{fwbootmgr}" {
		t.Fatalf("first entry id = %q", fw.ID)
	}
	if got := fw.Fields["displayorder"]; !reflect.DeepEqual(got, []string{"{bootmgr}", testWootcGUID}) {
		t.Fatalf("displayorder = %v", got)
	}
	if entries[2].Description != "wootc" || entries[2].ID != testWootcGUID {
		t.Fatalf("wootc entry parsed as %+v", entries[2])
	}
}

func TestPlanBootRepairStates(t *testing.T) {
	cases := []struct {
		name        string
		order, seq  []string
		extra       []string
		state       string
		restore     bool
		repair      bool
		recommended string
	}{
		{"one-shot armed after failure", []string{"{bootmgr}"}, []string{testWootcGUID}, []string{wootcApp},
			BootStateOneShotArmed, true, true, BootActionRestoreWindows},
		{"wootc ahead of windows", []string{testWootcGUID, "{bootmgr}"}, nil, []string{wootcApp},
			BootStateWootcDefault, true, true, BootActionRestoreWindows},
		{"wootc listed behind windows", []string{"{bootmgr}", testWootcGUID}, nil, []string{wootcApp},
			BootStateWootcListed, true, true, BootActionRestoreWindows},
		{"already windows-only", []string{"{bootmgr}"}, nil, []string{wootcApp},
			BootStateWindowsOnly, false, true, BootActionNone},
		{"next boot is someone else's", []string{"{bootmgr}"}, []string{testForeignGUID},
			[]string{wootcApp, firmwareApp(testForeignGUID, "Fedora", `\EFI\fedora\shimx64.efi`)},
			BootStateForeignNext, false, false, BootActionManual},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := planBootRepair(armedObservation(firmwareDump(c.order, c.seq, c.extra...)))
			if r.BootState != c.state || r.CanRestoreWindows != c.restore || r.CanRepairBoot != c.repair || r.Recommended != c.recommended {
				t.Fatalf("got state=%s restore=%v repair=%v rec=%s, want %s %v %v %s\nfindings=%v\nrefusals=%v",
					r.BootState, r.CanRestoreWindows, r.CanRepairBoot, r.Recommended,
					c.state, c.restore, c.repair, c.recommended, r.Findings, r.Refusals)
			}
		})
	}
}

// The heuristic AGENTS.md asks for: what does the check print if the thing
// it asserts never happened? An unreadable boot manager must never be called
// windows-only, and must never unlock a BCD write.
func TestPlanBootRepairRefusesWithoutObservation(t *testing.T) {
	for name, obs := range map[string]BootObservation{
		"bcdedit failed": func() BootObservation {
			// A partial dump next to an error is still not an observation.
			o := armedObservation(firmwareDump([]string{"{bootmgr}"}, []string{testWootcGUID}, wootcApp))
			o.FirmwareEnumErr = "access denied"
			return o
		}(),
		"no fwbootmgr in dump": armedObservation("garbage\r\n"),
		"no windows boot manager": armedObservation(strings.Replace(
			firmwareDump([]string{"{bootmgr}"}, []string{testWootcGUID}, wootcApp),
			"identifier              {bootmgr}", "identifier              {deadbeef}", 1)),
	} {
		t.Run(name, func(t *testing.T) {
			r := planBootRepair(obs)
			if r.BootState == BootStateWindowsOnly && name != "no windows boot manager" {
				t.Fatalf("reported windows-only without an observation")
			}
			if r.CanRestoreWindows || r.CanRepairBoot {
				t.Fatalf("allowed a BCD write without an observation: %+v", r)
			}
			if r.Recommended != BootActionManual || len(r.Refusals) == 0 {
				t.Fatalf("recommended %q with refusals %v", r.Recommended, r.Refusals)
			}
		})
	}
}

func TestPlanBootRepairRefusesUncertainOwnership(t *testing.T) {
	fw := firmwareDump([]string{"{bootmgr}"}, []string{testWootcGUID}, wootcApp)
	cases := map[string]func(*BootObservation){
		"recorded guid now names another entry": func(o *BootObservation) {
			o.FirmwareEnum = firmwareDump([]string{"{bootmgr}"}, []string{testWootcGUID},
				firmwareApp(testWootcGUID, "ubuntu", `\EFI\ubuntu\shimx64.efi`))
		},
		"armed.json and bcd-guid.txt disagree": func(o *BootObservation) {
			o.RecordedGUID = testForeignGUID
		},
		"manifest unreadable": func(o *BootObservation) {
			o.ManifestErr = "ambiguous whitespace in ESP ownership path"
		},
		"staged file no longer claimed": func(o *BootObservation) {
			o.OwnedESPFiles = o.OwnedESPFiles[1:]
		},
		"armed.json unreadable": func(o *BootObservation) {
			o.ArmedErr = "parsing armed.json: unexpected EOF"
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			obs := armedObservation(fw)
			mutate(&obs)
			r := planBootRepair(obs)
			if r.Ownership != OwnershipUncertain {
				t.Fatalf("ownership = %q, want uncertain", r.Ownership)
			}
			if r.CanRepairBoot {
				t.Fatalf("repair allowed with uncertain ownership: %v", r.Refusals)
			}
			// Doubt about the ESP or the install record must not block taking
			// wootc's own entries out of the boot order; doubt about the BCD
			// entries themselves must.
			bcdDoubt := strings.Contains(name, "guid") || strings.Contains(name, "disagree")
			if r.CanRestoreWindows == bcdDoubt {
				t.Fatalf("CanRestoreWindows = %v with BCD doubt = %v: %v", r.CanRestoreWindows, bcdDoubt, r.Refusals)
			}
		})
	}
}

func TestPlanBootRepairBlocksRepairAfterDeploy(t *testing.T) {
	for _, st := range []string{StateDeployed, StateHealthy} {
		obs := armedObservation(firmwareDump([]string{"{bootmgr}"}, nil, wootcApp))
		obs.Lifecycle.State = st
		if r := planBootRepair(obs); r.CanRepairBoot {
			t.Fatalf("%s: repair would overwrite the installed system's boot files", st)
		}
	}
	obs := armedObservation(firmwareDump([]string{"{bootmgr}"}, nil, wootcApp))
	obs.ArmedPresent = false
	if r := planBootRepair(obs); r.CanRepairBoot {
		t.Fatalf("repair allowed without armed.json")
	}
}

func TestPlanBootRepairReportsMissingAndChangedESPFiles(t *testing.T) {
	obs := armedObservation(firmwareDump([]string{"{bootmgr}"}, []string{testWootcGUID}, wootcApp))
	obs.CurrentHashes["efi/fedora/shimx64.efi"] = ""
	obs.CurrentHashes["efi/wootc/deployer-vmlinuz"] = "zz"
	r := planBootRepair(obs)
	joined := strings.Join(r.Findings, "\n")
	for _, want := range []string{"efi/fedora/shimx64.efi is missing", "efi/wootc/deployer-vmlinuz changed"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("findings missing %q:\n%s", want, joined)
		}
	}
	if !r.CanRepairBoot {
		t.Fatalf("a missing owned file is what repair is for: %v", r.Refusals)
	}
}

func TestRestoreWindowsCommandsTouchOnlyWootcEntries(t *testing.T) {
	r := planBootRepair(armedObservation(firmwareDump(
		[]string{testForeignGUID, testWootcGUID, "{bootmgr}"}, []string{testWootcGUID},
		wootcApp, firmwareApp(testForeignGUID, "Fedora", `\EFI\fedora\shimx64.efi`))))
	cmds, err := restoreWindowsCommands(r)
	if err != nil {
		t.Fatalf("restore refused: %v", err)
	}
	want := [][]string{
		{"/deletevalue", "{fwbootmgr}", "bootsequence"},
		{"/set", "{fwbootmgr}", "displayorder", testWootcGUID, "/remove"},
	}
	if !reflect.DeepEqual(cmds, want) {
		t.Fatalf("commands = %v, want %v", cmds, want)
	}
	for _, c := range cmds {
		if strings.Contains(strings.Join(c, " "), testForeignGUID) {
			t.Fatalf("command touches a foreign entry: %v", c)
		}
	}
}

func TestRestoreWindowsCommandsPutsMissingWindowsBack(t *testing.T) {
	r := planBootRepair(armedObservation(firmwareDump([]string{testWootcGUID}, nil, wootcApp)))
	cmds, err := restoreWindowsCommands(r)
	if err != nil {
		t.Fatalf("restore refused: %v", err)
	}
	last := cmds[len(cmds)-1]
	if !reflect.DeepEqual(last, []string{"/set", "{fwbootmgr}", "displayorder", "{bootmgr}", "/addfirst"}) {
		t.Fatalf("last command = %v", last)
	}
}

func TestVerifyWindowsOnlyNeedsTheObservedState(t *testing.T) {
	still := planBootRepair(armedObservation(firmwareDump([]string{"{bootmgr}"}, []string{testWootcGUID}, wootcApp)))
	if err := verifyWindowsOnly(still); err == nil {
		t.Fatalf("verified windows-only while the one-shot is still set")
	}
	unknown := armedObservation("")
	unknown.FirmwareEnumErr = "boom"
	if err := verifyWindowsOnly(planBootRepair(unknown)); err == nil {
		t.Fatalf("verified windows-only from an unreadable boot manager")
	}
	done := planBootRepair(armedObservation(firmwareDump([]string{"{bootmgr}"}, nil, wootcApp)))
	if err := verifyWindowsOnly(done); err != nil {
		t.Fatalf("clean state rejected: %v", err)
	}
}

func TestVerifyRepairArmedChecksEntryAndHashes(t *testing.T) {
	obs := armedObservation(firmwareDump([]string{"{bootmgr}"}, []string{testWootcGUID}, wootcApp))
	if err := verifyRepairArmed(planBootRepair(obs), obs); err != nil {
		t.Fatalf("good repair rejected: %v", err)
	}
	stale := obs
	stale.CurrentHashes = map[string]string{"efi/fedora/shimx64.efi": "aa", "efi/wootc/deployer-vmlinuz": "old"}
	if err := verifyRepairArmed(planBootRepair(stale), stale); err == nil {
		t.Fatalf("repair verified with a stale ESP file")
	}
	unarmed := armedObservation(firmwareDump([]string{"{bootmgr}"}, nil, wootcApp))
	if err := verifyRepairArmed(planBootRepair(unarmed), unarmed); err == nil {
		t.Fatalf("repair verified with no one-shot set")
	}
}

func TestWriteRepairBundleCollectsEvidence(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "install"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "state.json"), []byte(`{"state":"failed"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	obs := armedObservation(firmwareDump([]string{"{bootmgr}"}, []string{testWootcGUID}, wootcApp))
	dir, err := writeRepairBundle(root, obs, planBootRepair(obs))
	if err != nil {
		t.Fatalf("bundle: %v", err)
	}
	for _, f := range []string{"state.json", "report.json", "observation.json", "bcdedit-enum-firmware.txt", "index.txt"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			t.Fatalf("bundle lacks %s: %v", f, err)
		}
	}
	index, _ := os.ReadFile(filepath.Join(dir, "index.txt"))
	if !strings.Contains(string(index), "copied   state.json") || !strings.Contains(string(index), "missing  install/armed.json") {
		t.Fatalf("index does not say what was and was not collected:\n%s", index)
	}
}
