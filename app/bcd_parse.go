package main

import "strings"

// bootmgrListsItself reports whether `bcdedit /enum {bootmgr}` output shows
// Windows Boot Manager's own identifier in its displayorder (#551).
//
// That entry is a self-reference: the Windows boot menu then offers
// "Windows Boot Manager" as an OS to start, and choosing it loops back to the
// same menu. Older builds added it on every install with a bare
// `bcdedit /displayorder {bootmgr} /addfirst`.
//
// bcdedit prints one element per line; a list value continues on following
// lines that start with whitespace, and the next element starts at column 0.
func bootmgrListsItself(enumOut string) bool {
	inDisplayOrder := false
	for _, raw := range strings.Split(strings.ReplaceAll(enumOut, "\r\n", "\n"), "\n") {
		line := strings.TrimRight(raw, " \t")
		if line == "" {
			inDisplayOrder = false
			continue
		}
		startsElement := line[0] != ' ' && line[0] != '\t'
		if startsElement {
			fields := strings.Fields(line)
			inDisplayOrder = len(fields) > 0 && strings.EqualFold(fields[0], "displayorder")
			if !inDisplayOrder {
				continue
			}
			fields = fields[1:]
			for _, f := range fields {
				if strings.EqualFold(f, "{bootmgr}") {
					return true
				}
			}
			continue
		}
		if inDisplayOrder && strings.EqualFold(strings.TrimSpace(line), "{bootmgr}") {
			return true
		}
	}
	return false
}

// parseESPDiscovery splits findESP's PowerShell output into the drive letter
// and whether this run assigned it. A letter wootc assigned must be removed
// again when wootc is done with the ESP (#551): a visible EFI partition in
// Explorer invites users to delete boot files.
func parseESPDiscovery(out string) (letter string, assignedByUs bool) {
	s := strings.Trim(out, " \t\r\n\x00")
	if rest, ok := strings.CutPrefix(s, "ASSIGNED:"); ok {
		return strings.Trim(rest, " \t\r\n\x00"), true
	}
	return s, false
}
