package main

import (
	"crypto/x509"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// ── Secure Boot: which Microsoft UEFI CA does this machine trust? (#322) ──────
//
// Under Secure Boot the firmware will only launch a loader signed by a CA in
// its `db` variable. Microsoft's third-party authority exists in two
// generations: "Microsoft Corporation UEFI CA 2011" (certificate expired
// 2026-06-27) and "Microsoft UEFI CA 2023", which signs everything issued
// now. Firmware does not check expiry, so a machine holding the 2011 CA still
// boots a 2011-signed shim — but new machines increasingly ship the 2023 CA
// alone, and Microsoft's certificate rollout is adding it to existing ones.
//
// wootc stages a signed shim on the ESP and points the one-shot boot entry at
// it. If that shim is signed only by an authority this firmware does not hold,
// the reboot ends at "bad shim signature", the firmware falls back to Windows,
// and the user is told nothing. Asking BEFORE arming turns a silent failure
// after a reboot into a sentence on screen while Windows is still running.

// shimAuthorities is set at build time with
// -ldflags "-X main.shimAuthorities=2011,2023", from the signatures actually
// present on the shim that release stages (packaging/shim-authorities.py).
// Empty in a local build, which means "unknown" and gates nothing: a
// developer build must not refuse to install because the release pipeline
// did not stamp it.
var shimAuthorities = ""

// microsoftUefiCAPatterns maps a certificate issuer common name to the
// generation name the preflight and the release pipeline both speak. Matched
// on the ISSUER: the leaf is a per-publisher certificate, and it is the CA
// above it that has to be in the firmware's db.
var microsoftUefiCAPatterns = []struct {
	re  *regexp.Regexp
	gen string
}{
	{regexp.MustCompile(`Microsoft Corporation UEFI CA 2011`), "2011"},
	{regexp.MustCompile(`Microsoft (?:Corporation )?UEFI CA 2023`), "2023"},
}

// efiCertX509GUID is EFI_CERT_X509_GUID (a5c059a1-94e4-4aa7-87b5-ab155c2bf072)
// in the mixed-endian form UEFI writes into a signature list header.
var efiCertX509GUID = [16]byte{
	0xa1, 0x59, 0xc0, 0xa5, 0xe4, 0x94, 0xa7, 0x4a,
	0x87, 0xb5, 0xab, 0x15, 0x5c, 0x2b, 0xf0, 0x72,
}

// parseUEFISignatureListCAs walks an EFI_SIGNATURE_LIST chain (the raw
// contents of the `db` variable) and returns the Microsoft UEFI CA
// generations it contains, sorted and deduplicated.
//
// Layout per list: EFI_GUID SignatureType (16) | UINT32 SignatureListSize |
// UINT32 SignatureHeaderSize | UINT32 SignatureSize | SignatureHeader[] |
// EFI_SIGNATURE_DATA[] where each entry is EFI_GUID SignatureOwner (16)
// followed by the signature itself. For an X509 list the signature is a DER
// certificate. Non-X509 lists (SHA-256 hashes of individual binaries) carry
// no CA and are skipped.
//
// Malformed input yields what could be read rather than an error: a db we
// cannot fully parse still tells us about the entries we did understand, and
// "unknown" is the safe answer for the rest.
func parseUEFISignatureListCAs(db []byte) []string {
	seen := map[string]bool{}
	for off := 0; off+28 <= len(db); {
		var sigType [16]byte
		copy(sigType[:], db[off:off+16])
		listSize := le32(db, off+16)
		headerSize := le32(db, off+20)
		sigSize := le32(db, off+24)

		// A list that does not advance, overruns the buffer, or claims a
		// signature bigger than itself is corrupt; stop rather than loop.
		if listSize < 28 || sigSize <= 16 || off+int(listSize) > len(db) {
			break
		}
		if sigType == efiCertX509GUID {
			entries := off + 28 + int(headerSize)
			for entries+int(sigSize) <= off+int(listSize) {
				// Skip the 16-byte SignatureOwner GUID; the rest is DER.
				der := db[entries+16 : entries+int(sigSize)]
				if cert, err := x509.ParseCertificate(der); err == nil {
					for _, gen := range matchMicrosoftUefiCA(cert.Subject.CommonName) {
						seen[gen] = true
					}
				}
				entries += int(sigSize)
			}
		}
		off += int(listSize)
	}
	return sortedKeys(seen)
}

func le32(b []byte, off int) uint32 {
	if off < 0 || off+4 > len(b) {
		return 0
	}
	return uint32(b[off]) | uint32(b[off+1])<<8 | uint32(b[off+2])<<16 | uint32(b[off+3])<<24
}

// matchMicrosoftUefiCA returns the generation names a certificate subject or
// issuer string identifies. A single string can only be one generation, but
// returning a slice keeps the callers uniform.
func matchMicrosoftUefiCA(name string) []string {
	var out []string
	for _, p := range microsoftUefiCAPatterns {
		if p.re.MatchString(name) {
			out = append(out, p.gen)
		}
	}
	return out
}

func sortedKeys(m map[string]bool) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// stagedShimAuthorities returns the Microsoft CA generations that signed the
// shim this build stages, or nil when the build did not record them.
//
// A pre-staged shim-authorities.json under the install directory wins over
// the compiled-in value: the E2E harness and the offline bundle both assemble
// their own boot artifacts, and grading them against the release's stamp
// would be a lie in either direction.
func stagedShimAuthorities() []string {
	path := filepath.Join(wootcDir(), "install", "shim-authorities.json")
	if data, err := os.ReadFile(path); err == nil {
		var m map[string][]string
		if json.Unmarshal(data, &m) == nil {
			if gens, ok := m["shimx64.efi"]; ok {
				return normalizeAuthorities(gens)
			}
		}
	}
	if shimAuthorities == "" {
		return nil
	}
	return normalizeAuthorities(strings.Split(shimAuthorities, ","))
}

func normalizeAuthorities(in []string) []string {
	seen := map[string]bool{}
	for _, s := range in {
		if s = strings.TrimSpace(s); s != "" {
			seen[s] = true
		}
	}
	return sortedKeys(seen)
}

func intersects(a, b []string) bool {
	for _, x := range a {
		for _, y := range b {
			if x == y {
				return true
			}
		}
	}
	return false
}

// secureBootChainCheck is the preflight verdict on whether the shim this
// build stages can be launched by this machine's firmware.
type secureBootChainCheck struct {
	// Blocked is set only when BOTH sides are known AND they do not
	// intersect — the one case where we can say the reboot will fail.
	Blocked bool
	// Warn is set when Secure Boot is on but the firmware's db could not be
	// read. The install still proceeds: "bad shim signature" costs the user
	// a reboot back into Windows, not their data, and refusing every machine
	// whose SecureBoot module is unavailable would block PCs that work today.
	Warn    bool
	Message string
}

// checkSecureBootChain compares what the firmware trusts against what this
// build stages. secureBootOn/secureBootKnown come from the firmware probe;
// trusted is what parseUEFISignatureListCAs found in db; staged is
// stagedShimAuthorities().
func checkSecureBootChain(secureBootOn, secureBootKnown bool, trusted, staged []string) secureBootChainCheck {
	// Secure Boot off (or unknowable): the firmware launches whatever it is
	// pointed at, so the signing authority is not what stands in the way.
	if !secureBootKnown || !secureBootOn {
		return secureBootChainCheck{}
	}
	// A build that did not record what it stages cannot grade anything.
	if len(staged) == 0 {
		return secureBootChainCheck{}
	}
	if len(trusted) == 0 {
		return secureBootChainCheck{
			Warn: true,
			Message: "We could not read which certificates your PC's Secure Boot trusts, " +
				"so we cannot check the startup file in advance. If the restart ends up " +
				"back in Windows, that is why — nothing will be damaged, and you can " +
				"turn Secure Boot off temporarily and try again.",
		}
	}
	if intersects(trusted, staged) {
		return secureBootChainCheck{}
	}
	return secureBootChainCheck{
		Blocked: true,
		Message: fmt.Sprintf(
			"Your PC's Secure Boot trusts Microsoft's %s certificate, but this "+
				"version's startup file is signed with %s. Starting Linux would stop "+
				"at a \"bad shim signature\" message. Nothing has been changed. "+
				"Please update %s to a newer version, or turn Secure Boot off in your "+
				"PC's firmware settings and try again.",
			humanAuthorities(trusted), humanAuthorities(staged), productNameForMessages()),
	}
}

// humanAuthorities renders {"2011","2023"} as "2011 and 2023" for a sentence
// a non-technical reader can parse.
func humanAuthorities(gens []string) string {
	switch len(gens) {
	case 0:
		return "no known"
	case 1:
		return gens[0]
	case 2:
		return gens[0] + " and " + gens[1]
	default:
		return strings.Join(gens[:len(gens)-1], ", ") + " and " + gens[len(gens)-1]
	}
}

// productNameForMessages is the brand's product name, so a Bluefin user is
// told to update Bluefin rather than something called wootc.
func productNameForMessages() string {
	if n := effectiveBranding().ProductName; n != "" {
		return n
	}
	return "wootc"
}
