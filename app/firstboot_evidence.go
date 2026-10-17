package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// ── First-boot evidence (#332, docs/borrowed-from-libertix.md §3) ────────────
// The installed system's first boot measures itself and writes
// \wootc\install\installed-linux-boot.json (payload/migration/
// wootc-firstboot-evidence). state.json saying "healthy" is only that
// service's claim; Windows reports the installation healthy once the
// measurement it left behind matches this PC's own record of the install:
// the image the user selected, and the root.disk on this volume.
//
// The file is written from Linux onto a volume Windows owns, so it is read
// as untrusted input: bounded, strict JSON, no unknown, repeated or null
// fields, and every value checked before any of it is shown.

const (
	firstBootEvidenceName     = "installed-linux-boot.json"
	firstBootEvidenceMaxBytes = 16 * 1024
	firstBootRootDiskPath     = "/wootc/disks/root.disk"
)

// Verdicts of the cross-check. Only FirstBootVerified makes an install healthy.
const (
	FirstBootWaiting      = "waiting"      // no evidence yet: installed, waiting for the first boot
	FirstBootVerified     = "verified"     // evidence matches this installation
	FirstBootMismatch     = "mismatch"     // evidence describes a different image or root.disk
	FirstBootInvalid      = "invalid"      // evidence is unreadable, oversized or malformed
	FirstBootUnverifiable = "unverifiable" // this PC's own install record cannot be read
)

type FirstBootImage struct {
	Ref       string `json:"ref"`
	Digest    string `json:"digest"`
	SourceRef string `json:"sourceRef,omitempty"`
}

type FirstBootCurrent struct {
	BootNumber       string `json:"bootNumber,omitempty"`
	ESPPartitionGUID string `json:"espPartitionGuid,omitempty"`
	LoaderPath       string `json:"loaderPath,omitempty"`
	Source           string `json:"source"`
}

type FirstBootRootDisk struct {
	Path     string `json:"path"`
	HostUUID string `json:"hostUuid"`
}

type FirstBootBridge struct {
	BoundFolders      int  `json:"boundFolders"`
	MatchedUsers      int  `json:"matchedUsers"`
	BitlockerUnlocked bool `json:"bitlockerUnlocked"`
}

// FirstBootEvidence is the parsed installed-linux-boot.json.
type FirstBootEvidence struct {
	Schema      int               `json:"schema"`
	State       string            `json:"state"`
	PhaseID     string            `json:"phaseId,omitempty"`
	Sequence    int               `json:"sequence"`
	BootID      string            `json:"bootId"`
	Kernel      string            `json:"kernel"`
	Image       FirstBootImage    `json:"image"`
	BootCurrent FirstBootCurrent  `json:"bootCurrent"`
	RootDisk    FirstBootRootDisk `json:"rootDisk"`
	Bridge      FirstBootBridge   `json:"bridge"`
	SecureBoot  bool              `json:"secureBoot"`
	FailedUnits []string          `json:"failedUnits,omitempty"`
	WrittenAt   string            `json:"writtenAt"`
	UpdatedBy   string            `json:"updatedBy"`
}

// FirstBootAssessment is what status and the installed views report. It never
// carries a "state" key: the E2E harness reads the lifecycle state from the
// top-level "state" of `status` output.
type FirstBootAssessment struct {
	Verdict     string           `json:"verdict"`
	Message     string           `json:"message"`
	Reason      string           `json:"reason,omitempty"`
	Kernel      string           `json:"kernel,omitempty"`
	ImageRef    string           `json:"imageRef,omitempty"`
	ImageDigest string           `json:"imageDigest,omitempty"`
	BootID      string           `json:"bootId,omitempty"`
	SecureBoot  *bool            `json:"secureBoot,omitempty"`
	Bridge      *FirstBootBridge `json:"bridge,omitempty"`
	WrittenAt   string           `json:"writtenAt,omitempty"`
}

func firstBootEvidencePath(root string) string {
	return filepath.Join(root, "install", firstBootEvidenceName)
}

// ── Strict decoding ──────────────────────────────────────────────────────────

type strictKind int

const (
	strictString strictKind = iota
	strictBool
	strictInt
	strictStrings
	strictObject
)

type strictField struct {
	kind     strictKind
	required bool
	object   map[string]strictField
}

var firstBootEvidenceSchema = map[string]strictField{
	"schema":   {kind: strictInt, required: true},
	"state":    {kind: strictString, required: true},
	"phaseId":  {kind: strictString},
	"sequence": {kind: strictInt, required: true},
	"bootId":   {kind: strictString, required: true},
	"kernel":   {kind: strictString, required: true},
	"image": {kind: strictObject, required: true, object: map[string]strictField{
		"ref":       {kind: strictString, required: true},
		"digest":    {kind: strictString, required: true},
		"sourceRef": {kind: strictString},
	}},
	"bootCurrent": {kind: strictObject, required: true, object: map[string]strictField{
		"bootNumber":       {kind: strictString},
		"espPartitionGuid": {kind: strictString},
		"loaderPath":       {kind: strictString},
		"source":           {kind: strictString, required: true},
	}},
	"rootDisk": {kind: strictObject, required: true, object: map[string]strictField{
		"path":     {kind: strictString, required: true},
		"hostUuid": {kind: strictString, required: true},
	}},
	"bridge": {kind: strictObject, required: true, object: map[string]strictField{
		"boundFolders":      {kind: strictInt, required: true},
		"matchedUsers":      {kind: strictInt, required: true},
		"bitlockerUnlocked": {kind: strictBool, required: true},
	}},
	"secureBoot":  {kind: strictBool, required: true},
	"failedUnits": {kind: strictStrings},
	"writtenAt":   {kind: strictString, required: true},
	"updatedBy":   {kind: strictString, required: true},
}

// checkStrictJSON refuses anything json.Unmarshal would silently accept:
// unknown or case-folded keys, repeated keys (last one wins), nulls, floats
// for integers, and trailing data.
func checkStrictJSON(data []byte, schema map[string]strictField) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := checkStrictObject(decoder, schema, ""); err != nil {
		return err
	}
	if _, err := decoder.Token(); err != io.EOF {
		return fmt.Errorf("trailing data after the record")
	}
	return nil
}

func checkStrictObject(decoder *json.Decoder, schema map[string]strictField, path string) error {
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return fmt.Errorf("%s must be an object", strings.TrimSuffix("record."+path, "."))
	}
	seen := map[string]bool{}
	for decoder.More() {
		token, err = decoder.Token()
		key, ok := token.(string)
		field, known := schema[key]
		if err != nil || !ok || !known || seen[key] {
			return fmt.Errorf("unsupported or repeated field %q", path+fmt.Sprint(token))
		}
		seen[key] = true
		if field.kind == strictObject {
			if err := checkStrictObject(decoder, field.object, path+key+"."); err != nil {
				return err
			}
			continue
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return err
		}
		if err := checkStrictValue(raw, field.kind); err != nil {
			return fmt.Errorf("field %q: %w", path+key, err)
		}
	}
	if _, err := decoder.Token(); err != nil {
		return err
	}
	for key, field := range schema {
		if field.required && !seen[key] {
			return fmt.Errorf("missing field %q", path+key)
		}
	}
	return nil
}

func checkStrictValue(raw json.RawMessage, kind strictKind) error {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return fmt.Errorf("null value")
	}
	switch kind {
	case strictString:
		var s string
		return json.Unmarshal(raw, &s)
	case strictBool:
		var b bool
		return json.Unmarshal(raw, &b)
	case strictInt:
		var n int64
		return json.Unmarshal(raw, &n)
	case strictStrings:
		var items []json.RawMessage
		if err := json.Unmarshal(raw, &items); err != nil {
			return err
		}
		for _, item := range items {
			var s string
			if bytes.Equal(bytes.TrimSpace(item), []byte("null")) {
				return fmt.Errorf("null list item")
			}
			if err := json.Unmarshal(item, &s); err != nil {
				return err
			}
		}
		return nil
	}
	return fmt.Errorf("unsupported field contract")
}

// ── Parsing and validation ──────────────────────────────────────────────────

var (
	firstBootUUIDPattern   = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)
	firstBootDigestPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
	firstBootHostPattern   = regexp.MustCompile(`^[0-9A-F]{16}$`)
	firstBootNumberPattern = regexp.MustCompile(`^[0-9A-F]{4}$`)
	firstBootUnitPattern   = regexp.MustCompile(`^[A-Za-z0-9@._:\\-]{1,128}$`)
)

func firstBootText(value string, limit int) bool {
	if value == "" || len(value) > limit {
		return false
	}
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

// parseFirstBootEvidence decodes and validates a record already bounded by
// the reader. It does not compare the record with this installation.
func parseFirstBootEvidence(data []byte) (FirstBootEvidence, error) {
	var ev FirstBootEvidence
	if len(data) > firstBootEvidenceMaxBytes {
		return ev, fmt.Errorf("record exceeds %d bytes", firstBootEvidenceMaxBytes)
	}
	data = bytes.TrimPrefix(data, []byte{0xef, 0xbb, 0xbf})
	if err := checkStrictJSON(data, firstBootEvidenceSchema); err != nil {
		return ev, err
	}
	if err := json.Unmarshal(data, &ev); err != nil {
		return FirstBootEvidence{}, err
	}
	return ev, validateFirstBootEvidence(ev)
}

func validateFirstBootEvidence(ev FirstBootEvidence) error {
	switch {
	case ev.Schema != 1:
		return fmt.Errorf("unsupported schema %d", ev.Schema)
	case ev.State != StateHealthy:
		return fmt.Errorf("unsupported state %q", ev.State)
	case ev.PhaseID != "" && ev.PhaseID != StepFirstbootFirstbootEvidence:
		return fmt.Errorf("unsupported phase")
	case ev.Sequence < 1 || ev.Sequence > 1<<20:
		return fmt.Errorf("invalid sequence")
	case !firstBootUUIDPattern.MatchString(ev.BootID):
		return fmt.Errorf("invalid boot ID")
	case !firstBootText(ev.Kernel, 128):
		return fmt.Errorf("invalid kernel release")
	case !firstBootText(ev.Image.Ref, 512):
		return fmt.Errorf("invalid image reference")
	case !firstBootDigestPattern.MatchString(ev.Image.Digest):
		return fmt.Errorf("invalid image digest")
	case ev.Image.SourceRef != "" && !firstBootText(ev.Image.SourceRef, 512):
		return fmt.Errorf("invalid source image reference")
	case ev.RootDisk.Path != firstBootRootDiskPath:
		return fmt.Errorf("unsupported root.disk path")
	case !firstBootHostPattern.MatchString(ev.RootDisk.HostUUID):
		return fmt.Errorf("invalid host volume identity")
	case ev.Bridge.BoundFolders < 0 || ev.Bridge.BoundFolders > 4096 ||
		ev.Bridge.MatchedUsers < 0 || ev.Bridge.MatchedUsers > ev.Bridge.BoundFolders:
		return fmt.Errorf("invalid bridge summary")
	case len(ev.FailedUnits) > 64:
		return fmt.Errorf("too many failed units")
	case ev.UpdatedBy != "wootc-firstboot":
		return fmt.Errorf("unsupported writer")
	}
	if _, err := time.Parse(time.RFC3339, ev.WrittenAt); err != nil {
		return fmt.Errorf("invalid write time")
	}
	for _, unit := range ev.FailedUnits {
		if !firstBootUnitPattern.MatchString(unit) {
			return fmt.Errorf("invalid failed unit name")
		}
	}
	bc := ev.BootCurrent
	switch bc.Source {
	case "efivarfs", "efibootmgr", "unavailable":
	default:
		return fmt.Errorf("unsupported BootCurrent source")
	}
	if (bc.BootNumber != "" && !firstBootNumberPattern.MatchString(bc.BootNumber)) ||
		(bc.ESPPartitionGUID != "" && !firstBootUUIDPattern.MatchString(bc.ESPPartitionGUID)) ||
		(bc.LoaderPath != "" && (!firstBootText(bc.LoaderPath, 260) || !strings.HasPrefix(bc.LoaderPath, `\EFI\`))) {
		return fmt.Errorf("invalid BootCurrent")
	}
	return nil
}

// ── This installation ───────────────────────────────────────────────────────

// volumeSerial is the identity of the NTFS volume that holds root.disk. Linux
// reports the 64-bit NTFS serial as the volume UUID (blkid). Windows exposes
// all 64 bits to an administrator and the low 32 bits to anyone.
type volumeSerial struct {
	serial64 uint64
	have64   bool
	serial32 uint32
	have32   bool
}

// firstBootVolumeSerial is swappable so tests stand in a volume.
var firstBootVolumeSerial = platformVolumeSerial

type firstBootExpectation struct {
	imageRef    string
	imageDigest string // "" when this PC did not download the image itself
	volume      volumeSerial
}

// expectFirstBootIdentity reads what this PC recorded about the install under
// an already audited state root.
func expectFirstBootIdentity(root string) (firstBootExpectation, error) {
	var exp firstBootExpectation
	journal, found, err := readNativeInstallJournal(filepath.Join(root, "install", "journal.json"))
	if err != nil {
		return exp, fmt.Errorf("install journal: %w", err)
	}
	if found {
		exp.imageRef = journal.ImageRef
	}
	bundle := readBundleInfoAt(filepath.Join(root, "bundle"))
	if exp.imageRef == "" && bundle != nil {
		exp.imageRef = bundle.Image
	}
	if exp.imageRef == "" {
		return exp, fmt.Errorf("no record of the selected image")
	}
	if bundle != nil && bundle.Image == exp.imageRef && firstBootDigestPattern.MatchString(bundle.Digest) {
		exp.imageDigest = bundle.Digest
	}
	present, _, err := nativeRegularFile(filepath.Join(root, "disks", "root.disk"))
	if err != nil {
		return exp, err
	}
	if !present {
		return exp, fmt.Errorf("root.disk is not on this volume")
	}
	if exp.volume, err = firstBootVolumeSerial(root); err != nil {
		return exp, fmt.Errorf("volume identity: %w", err)
	}
	return exp, nil
}

// checkFirstBootEvidence compares a valid record with this installation.
func checkFirstBootEvidence(ev FirstBootEvidence, exp firstBootExpectation) error {
	// The deployer may install a locally derived image (an NTFS driver added),
	// so the booted reference can differ from the selection; the reference it
	// recorded for updates (sourceRef) cannot.
	if ev.Image.SourceRef != "" && ev.Image.SourceRef != exp.imageRef {
		return fmt.Errorf("first boot was installed from %s, not the selected %s", ev.Image.SourceRef, exp.imageRef)
	}
	if ev.Image.Ref != exp.imageRef && ev.Image.SourceRef != exp.imageRef {
		return fmt.Errorf("first boot ran %s, not the selected %s", ev.Image.Ref, exp.imageRef)
	}
	if exp.imageDigest != "" && ev.Image.Ref == exp.imageRef && ev.Image.Digest != exp.imageDigest {
		return fmt.Errorf("first boot ran digest %s, not the downloaded %s", ev.Image.Digest, exp.imageDigest)
	}
	host, err := strconv.ParseUint(ev.RootDisk.HostUUID, 16, 64)
	if err != nil {
		return fmt.Errorf("invalid host volume identity")
	}
	switch {
	case exp.volume.have64:
		if host != exp.volume.serial64 {
			return fmt.Errorf("first boot used root.disk on volume %016X, not this volume (%016X)", host, exp.volume.serial64)
		}
	case exp.volume.have32:
		if uint32(host) != exp.volume.serial32 {
			return fmt.Errorf("first boot used root.disk on volume %016X, not this volume (serial %08X)", host, exp.volume.serial32)
		}
	default:
		return fmt.Errorf("this volume's identity is unavailable")
	}
	return nil
}

// assessFirstBootAt reads and cross-checks the evidence under an audited root.
func assessFirstBootAt(root string) FirstBootAssessment {
	name := installedSystemName()
	data, err := readBoundedRecord(firstBootEvidencePath(root), firstBootEvidenceMaxBytes)
	if os.IsNotExist(err) {
		return FirstBootAssessment{Verdict: FirstBootWaiting,
			Message: fmt.Sprintf("%s is installed, waiting for its first boot.", name)}
	}
	invalid := func(err error) FirstBootAssessment {
		return FirstBootAssessment{Verdict: FirstBootInvalid, Reason: err.Error(),
			Message: fmt.Sprintf("%s is installed, but the report from its first boot could not be read.", name)}
	}
	if err != nil {
		return invalid(err)
	}
	ev, err := parseFirstBootEvidence(data)
	if err != nil {
		return invalid(err)
	}
	exp, err := expectFirstBootIdentity(root)
	if err != nil {
		return FirstBootAssessment{Verdict: FirstBootUnverifiable, Reason: err.Error(),
			Message: fmt.Sprintf("%s is installed, but this PC's record of the installation cannot confirm its first boot.", name)}
	}
	if err := checkFirstBootEvidence(ev, exp); err != nil {
		return FirstBootAssessment{Verdict: FirstBootMismatch, Reason: err.Error(),
			Message: fmt.Sprintf("%s is installed, but the report from its first boot does not match this installation.", name)}
	}
	secure, bridge := ev.SecureBoot, ev.Bridge
	return FirstBootAssessment{
		Verdict: FirstBootVerified,
		Message: fmt.Sprintf("%s started and reported that it is healthy.", name),
		Kernel:  ev.Kernel, ImageRef: ev.Image.Ref, ImageDigest: ev.Image.Digest, BootID: ev.BootID,
		SecureBoot: &secure, Bridge: &bridge, WrittenAt: ev.WrittenAt,
	}
}

// verifiedLifecycleAt is the lifecycle a user is told about: state.json's
// "healthy" stands only when the first-boot evidence matches this install.
// Anything else is reported as installed and waiting ("deployed").
func verifiedLifecycleAt(root string, state LifecycleState) (LifecycleState, *FirstBootAssessment) {
	if state.State != StateDeployed && state.State != StateHealthy {
		return state, nil
	}
	assessment := assessFirstBootAt(root)
	if state.State == StateHealthy && assessment.Verdict != FirstBootVerified {
		state.State = StateDeployed
	}
	return state, &assessment
}

// readVerifiedState is readState with the first-boot cross-check applied.
func readVerifiedState() (LifecycleState, bool) {
	state, ok := readState()
	if !ok {
		return state, false
	}
	state, _ = verifiedLifecycleAt(wootcDir(), state)
	return state, true
}

// StatusReport is what `wootc status` prints: the lifecycle (top-level
// fields, as before), the state.json value when the cross-check overruled it,
// and the first-boot verdict once the deployer has finished.
type StatusReport struct {
	LifecycleState
	RecordedState string               `json:"recordedState,omitempty"`
	FirstBoot     *FirstBootAssessment `json:"firstBoot,omitempty"`
}

func statusReportAt(root string, recorded LifecycleState) StatusReport {
	state, assessment := verifiedLifecycleAt(root, recorded)
	report := StatusReport{LifecycleState: state, FirstBoot: assessment}
	if state.State != recorded.State {
		report.RecordedState = recorded.State
	}
	return report
}

// discardStaleFirstBootEvidence removes a previous installation's record
// before a new one starts. Left in place it would both vouch for the wrong
// install and stop the new first boot from writing its own (the unit runs
// only while the file is absent).
func discardStaleFirstBootEvidence(root string) error {
	path := firstBootEvidencePath(root)
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove the previous installation's first-boot record %s: %w", path, err)
	}
	return nil
}
