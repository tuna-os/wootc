package main

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"math/big"
	"strings"
	"testing"
	"time"
)

// ── Building a real db blob to parse ──────────────────────────────────────
// Hand-written hex would only prove the parser matches whatever the test
// author believed the layout was. Generating actual X.509 certificates and
// wrapping them in a real EFI_SIGNATURE_LIST means a parser bug shows up as
// a failing test rather than as "bad shim signature" on somebody's PC.

func selfSigned(t *testing.T, commonName string) []byte {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: commonName, Organization: []string{"Microsoft Corporation"}},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}
	return der
}

// signatureList wraps DER certificates in one EFI_SIGNATURE_LIST. Every
// entry in a list must be the same size, so callers group by size or pass
// one certificate at a time — which is what real firmware does too.
func signatureList(sigType [16]byte, certs ...[]byte) []byte {
	sigSize := 0
	for _, c := range certs {
		if 16+len(c) > sigSize {
			sigSize = 16 + len(c)
		}
	}
	out := make([]byte, 0, 28+len(certs)*sigSize)
	out = append(out, sigType[:]...)
	var hdr [12]byte
	binary.LittleEndian.PutUint32(hdr[0:], uint32(28+len(certs)*sigSize)) // SignatureListSize
	binary.LittleEndian.PutUint32(hdr[4:], 0)                             // SignatureHeaderSize
	binary.LittleEndian.PutUint32(hdr[8:], uint32(sigSize))               // SignatureSize
	out = append(out, hdr[:]...)
	for _, c := range certs {
		entry := make([]byte, sigSize)
		copy(entry[16:], c) // first 16 bytes are the SignatureOwner GUID
		out = append(out, entry...)
	}
	return out
}

func TestParseUEFISignatureListFindsBothCAGenerations(t *testing.T) {
	db := signatureList(efiCertX509GUID, selfSigned(t, "Microsoft Corporation UEFI CA 2011"))
	db = append(db, signatureList(efiCertX509GUID, selfSigned(t, "Microsoft UEFI CA 2023"))...)
	db = append(db, signatureList(efiCertX509GUID, selfSigned(t, "Some OEM Platform Key"))...)

	got := parseUEFISignatureListCAs(db)
	if len(got) != 2 || got[0] != "2011" || got[1] != "2023" {
		t.Fatalf("parseUEFISignatureListCAs = %v, want [2011 2023]", got)
	}
}

func TestParseUEFISignatureListIgnoresNonX509Lists(t *testing.T) {
	// A db commonly also holds SHA-256 hashes of individual revoked or
	// allowed binaries. Those lists carry no certificate; treating their
	// bytes as DER must not invent an authority, and must not stop the walk
	// before the X509 list that follows.
	var sha256Type [16]byte
	sha256Type[0] = 0x26 // any GUID that is not EFI_CERT_X509_GUID
	hashes := make([]byte, 32)
	db := signatureList(sha256Type, hashes)
	db = append(db, signatureList(efiCertX509GUID, selfSigned(t, "Microsoft UEFI CA 2023"))...)

	got := parseUEFISignatureListCAs(db)
	if len(got) != 1 || got[0] != "2023" {
		t.Fatalf("parseUEFISignatureListCAs = %v, want [2023]", got)
	}
}

func TestParseUEFISignatureListSurvivesTruncation(t *testing.T) {
	// A short read of the variable must not panic or loop forever; it
	// reports what it could read, and "unknown" covers the rest.
	db := signatureList(efiCertX509GUID, selfSigned(t, "Microsoft Corporation UEFI CA 2011"))
	for _, cut := range []int{0, 1, 27, 28, len(db) / 2, len(db) - 1} {
		if got := parseUEFISignatureListCAs(db[:cut]); len(got) > 1 {
			t.Fatalf("truncated at %d returned %v", cut, got)
		}
	}
	// A list claiming zero size would spin forever if the walk trusted it.
	spin := make([]byte, 28)
	copy(spin, efiCertX509GUID[:])
	done := make(chan []string, 1)
	go func() { done <- parseUEFISignatureListCAs(spin) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("parseUEFISignatureListCAs did not terminate on a zero-size list")
	}
}

// ── The verdict: the whole point is that it fires ONLY on a known mismatch ──

func TestSecureBootChainBlocksOnlyOnAKnownMismatch(t *testing.T) {
	cases := []struct {
		name                  string
		on, known             bool
		trusted, staged       []string
		wantBlocked, wantWarn bool
	}{
		{"2023-only firmware, 2011-only shim: the failure this exists to prevent",
			true, true, []string{"2023"}, []string{"2011"}, true, false},
		{"2011-only firmware, 2023-only shim: the same failure the other way",
			true, true, []string{"2011"}, []string{"2023"}, true, false},
		{"dual-signed shim satisfies either firmware",
			true, true, []string{"2023"}, []string{"2011", "2023"}, false, false},
		{"overlapping sets are fine",
			true, true, []string{"2011", "2023"}, []string{"2011"}, false, false},
		{"db unreadable warns, never blocks: refusing every PC whose SecureBoot module is missing would be worse than a recoverable reboot",
			true, true, nil, []string{"2011"}, false, true},
		{"Secure Boot off: the signing authority is not what stands in the way",
			false, true, nil, []string{"2011"}, false, false},
		{"Secure Boot state unknown: nothing to grade against",
			false, false, []string{"2023"}, []string{"2011"}, false, false},
		{"a build that did not record what it stages cannot grade anything",
			true, true, []string{"2023"}, nil, false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := checkSecureBootChain(tc.on, tc.known, tc.trusted, tc.staged)
			if got.Blocked != tc.wantBlocked || got.Warn != tc.wantWarn {
				t.Fatalf("blocked=%v warn=%v, want blocked=%v warn=%v",
					got.Blocked, got.Warn, tc.wantBlocked, tc.wantWarn)
			}
			if (got.Blocked || got.Warn) && got.Message == "" {
				t.Fatal("a verdict that stops or warns the user must say why")
			}
		})
	}
}

func TestSecureBootRefusalSaysWhatToDoAndThatNothingChanged(t *testing.T) {
	// The moment of maximum fear: the user is told no. The sentence has to
	// carry the reassurance and the two ways out, or it reads as a dead end.
	v := checkSecureBootChain(true, true, []string{"2023"}, []string{"2011"})
	for _, want := range []string{"Nothing has been changed", "Secure Boot off", "2023", "2011"} {
		if !strings.Contains(v.Message, want) {
			t.Errorf("refusal does not mention %q:\n%s", want, v.Message)
		}
	}
	// It must not leak the internals a nervous reader cannot act on.
	for _, forbidden := range []string{"EFI_SIGNATURE_LIST", "db variable", "Authenticode"} {
		if strings.Contains(v.Message, forbidden) {
			t.Errorf("refusal leaks %q at the user:\n%s", forbidden, v.Message)
		}
	}
}

func TestStagedShimAuthoritiesParsesTheBuildStamp(t *testing.T) {
	old := shimAuthorities
	t.Cleanup(func() { shimAuthorities = old })

	shimAuthorities = ""
	if got := stagedShimAuthorities(); got != nil {
		t.Errorf("an unstamped build must report unknown, got %v", got)
	}
	shimAuthorities = "2023, 2011 ,,2023"
	got := stagedShimAuthorities()
	if len(got) != 2 || got[0] != "2011" || got[1] != "2023" {
		t.Errorf("stagedShimAuthorities = %v, want [2011 2023] deduped and sorted", got)
	}
}

func TestHumanAuthoritiesReadsAsASentence(t *testing.T) {
	for in, want := range map[string]string{
		"2011":           "2011",
		"2011,2023":      "2011 and 2023",
		"2011,2023,2030": "2011, 2023 and 2030",
	} {
		if got := humanAuthorities(strings.Split(in, ",")); got != want {
			t.Errorf("humanAuthorities(%q) = %q, want %q", in, got, want)
		}
	}
}
