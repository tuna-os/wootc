//go:build windows

package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"golang.org/x/sys/windows"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestNativeConfigurationActualPreparedStorageSnapshots(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	session, err := startNativeStorageSession(ctx)
	if err != nil {
		retainNativeStorageQueryFailure(t, err)
		t.Fatal(err)
	}
	defer session.close(true)
	before, err := session.query(ctx)
	if err != nil {
		retainNativeStorageQueryFailure(t, err)
		t.Fatal(err)
	}
	// This real parent boundary lies between the two requests, not after two
	// snapshots that the child eagerly captured before metadata observation.
	if session.sequence != 1 {
		t.Fatal("first observation sequence unavailable")
	}
	after, err := session.query(ctx)
	if err != nil {
		retainNativeStorageQueryFailure(t, err)
		t.Fatal(err)
	}
	if len(before) != len(after) {
		t.Fatal("actual storage set changed")
	}
	for i := range before {
		if before[i] != after[i] {
			t.Fatal("actual storage identity or protection changed")
		}
	}
	if !session.exited || !session.drained || session.exitCode != 0 {
		t.Fatal("owned helper did not terminate")
	}
	raw := session.stderr.Bytes()
	if strings.Count(string(raw), "storage-phase|import-storage\r\n") != 1 || strings.Count(string(raw), "storage-phase|read-volumes\r\n") != 2 {
		t.Fatal("helper did not import once and re-read both inventories")
	}
	if !strings.Contains(string(raw), "storage-cost|import-storage|") || !strings.Contains(string(raw), "storage-cost|read-protection|") {
		t.Fatal("actual stage cost observations missing")
	}
	lastCost := int64(-1)
	for _, line := range strings.Split(string(raw), "\n") {
		pieces := strings.Split(strings.TrimSuffix(line, "\r"), "|")
		if len(pieces) != 3 || pieces[0] != "storage-cost" {
			continue
		}
		cost, parseErr := strconv.ParseInt(pieces[2], 10, 64)
		if parseErr != nil || cost < lastCost || cost > 60000 || nativeStoragePhase([]byte("storage-phase|"+pieces[1])) == "no-child-phase-observed" {
			t.Fatal("fixed child stage cost refused")
		}
		lastCost = cost
	}
	if lastCost < 0 {
		t.Fatal("child cost timeline absent")
	}
	base := os.Getenv("WOOTC_NATIVE_QUERY_PROOF_DIR")
	if base == "" {
		t.Fatal("private proof directory required")
	}
	if err = os.MkdirAll(base, 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(base, t.Name()+".stderr.raw"), raw, 0600); err != nil {
		t.Fatal(err)
	}
}

// These controls run the actual owned helper/pipe/frame adapter with public
// synthetic rows. They exercise transport refusal, not actual CIM state changes.
func TestNativeConfigurationPreparedStorageTransportRefusals(t *testing.T) {
	original := nativeStorageQuery
	defer func() { nativeStorageQuery = original }()
	good := `$nonce=$env:WOOTC_NATIVE_STORAGE_SESSION
for ($sequence=1; $sequence -le 2; $sequence++) {
 $request=[Console]::In.ReadLine()
 $json='{"schemaVersion":1,"nonce":"'+$nonce+'","sequence":'+$sequence+',"pid":'+$PID+',"rows":[]}'
 [Console]::Out.WriteLine($json);[Console]::Out.Flush()
}`
	for _, change := range []string{"nonce", "pid", "sequence", "replayed-first", "duplicate", "extra-output", "blocked-second", "parent-cancel", "held-stderr", "stderr-overflow"} {
		t.Run(change, func(t *testing.T) {
			nativeStorageQuery = good
			switch change {
			case "nonce":
				nativeStorageQuery = strings.Replace(good, "$nonce+'", "'ffffffffffffffffffffffffffffffff'+'", 1)
			case "pid":
				nativeStorageQuery = strings.Replace(good, "+$PID+", "+1+", 1)
			case "sequence":
				nativeStorageQuery = strings.Replace(good, "+$sequence+", "+0+", 1)
			case "replayed-first":
				nativeStorageQuery = strings.Replace(good, "+$sequence+", "+1+", 1)
			case "duplicate":
				nativeStorageQuery = strings.Replace(good, `"schemaVersion":1,`, `"schemaVersion":1,"schemaVersion":1,`, 1)
			case "extra-output":
				nativeStorageQuery = good + "\n[Console]::Out.WriteLine('foreign-output')"
			case "stderr-overflow":
				nativeStorageQuery = good + "\n[Console]::Error.WriteLine([string]::new([char]'x',70000))"
			case "held-stderr":
				assembly, digest := prepareNativeHeldStderrAssembly(t, good)
				child := `[Console]::Error.WriteLine("held-fixture-before-assembly-load")
$assemblyPath='` + strings.ReplaceAll(assembly, "'", "''") + `'
$assemblyBytes=[System.IO.File]::ReadAllBytes($assemblyPath)
$sha=[System.Security.Cryptography.SHA256]::Create()
$actual=[System.BitConverter]::ToString($sha.ComputeHash($assemblyBytes)).Replace('-','').ToLowerInvariant()
if ($actual -ne '` + digest + `') {throw 'Owned fixture assembly identity refused'}
[System.Reflection.Assembly]::Load($assemblyBytes) | Out-Null
[Console]::Error.WriteLine("held-fixture-after-assembly-load")
if (-not [PipeControl]::SetHandleInformation([PipeControl]::GetStdHandle(-11),1,0)) {throw 'Owned stdout inheritance refusal'}
$code="[Console]::Error.WriteLine('owned-descendant-started'); [System.Threading.Thread]::Sleep(30000)"
$encoded=[System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))
$info=[System.Diagnostics.ProcessStartInfo]::new()
$info.FileName="$PSHOME\powershell.exe"
$info.Arguments="-NoProfile -NonInteractive -EncodedCommand $encoded"
$info.UseShellExecute=$false
$info.RedirectStandardOutput=$true
$info.CreateNoWindow=$true
$child=[System.Diagnostics.Process]::Start($info)
[Console]::Error.WriteLine("held-fixture-child-start-returned")
[System.Threading.Thread]::Sleep(1500)
`
				nativeStorageQuery = child + good
			case "blocked-second":
				nativeStorageQuery = strings.Replace(good, " $request=", " if ($sequence -eq 2) { [System.Threading.Thread]::Sleep(30000) }\n $request=", 1)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			deadline, hasDeadline := ctx.Deadline()
			if !hasDeadline || time.Until(deadline) > 5*time.Second {
				t.Fatal("synthetic observation deadline exceeded five seconds")
			}
			session, err := startNativeStorageSession(ctx)
			if err != nil {
				retainNativeStorageQueryFailure(t, err)
				t.Fatal(err)
			}
			defer session.close(true)
			_, err = session.query(ctx)
			if change == "replayed-first" || change == "extra-output" || change == "blocked-second" || change == "parent-cancel" || change == "held-stderr" || change == "stderr-overflow" {
				if err != nil {
					retainNativeStorageQueryFailure(t, err)
					t.Fatal("first synthetic observation unavailable", err)
				}
				if change == "parent-cancel" {
					cancel()
				}
				_, err = session.query(ctx)
			}
			if err == nil {
				retainNativeStorageQueryFailure(t, session.failure())
				t.Fatal("invalid prepared helper observation accepted")
			}
			retainNativeStorageQueryFailure(t, err)
			if !session.streamsJoined {
				t.Fatal("stderr reader termination unknown")
			}
			if change == "held-stderr" && (!session.streamsJoined || !session.forcedCleanup || !strings.Contains(string(session.stderr.Bytes()), "owned-descendant-started") || !strings.Contains(string(session.stderr.Bytes()), "held-fixture-after-assembly-load") || !strings.Contains(string(session.stderr.Bytes()), "held-fixture-child-start-returned")) {
				t.Fatal("actual held-stderr child/forced cleanup not observed")
			}
			if change == "stderr-overflow" && session.stderrErr == nil {
				t.Fatal("stderr overflow was not observed")
			}
			if !session.exited || !session.drained {
				t.Fatal("refused owned helper not reaped")
			}
		})
	}
}

// Cold compilation runs as bounded fixture preparation before the unchanged
// five-second observation deadline. The timed helper loads these exact bytes
// and still spawns a real descendant holding its inherited stderr pipe.
func prepareNativeHeldStderrAssembly(t *testing.T, good string) (string, string) {
	t.Helper()
	directory := t.TempDir()
	sd, err := windows.SecurityDescriptorFromString(stateDirectorySDDL)
	if err != nil {
		t.Fatal(err)
	}
	acl, _, err := sd.DACL()
	if err != nil {
		t.Fatal(err)
	}
	if err = windows.SetNamedSecurityInfo(directory, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, acl, nil); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(directory, "held-fixture.dll")
	original := nativeStorageQuery
	defer func() { nativeStorageQuery = original }()
	nativeStorageQuery = `[Console]::Error.WriteLine("held-fixture-compile-start")
Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public static class PipeControl{[DllImport("kernel32.dll")]public static extern IntPtr GetStdHandle(int n);[DllImport("kernel32.dll")]public static extern bool SetHandleInformation(IntPtr h,uint mask,uint flags);}' -OutputAssembly '` + strings.ReplaceAll(path, "'", "''") + `' -ErrorAction Stop
[Console]::Error.WriteLine("held-fixture-compile-complete")
` + good
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	session, err := startNativeStorageSession(ctx)
	if err != nil {
		retainNativeStorageQueryFailure(t, err)
		t.Fatal(err)
	}
	defer session.close(true)
	for range 2 {
		if _, err = session.query(ctx); err != nil {
			retainNativeStorageQueryFailure(t, err)
			t.Fatal("bounded fixture compilation failed", err)
		}
	}
	if !session.exited || !session.drained || !session.streamsJoined || session.forcedCleanup || session.exitCode != 0 || !strings.Contains(string(session.stderr.Bytes()), "held-fixture-compile-complete") {
		retainNativeStorageQueryFailure(t, session.failure())
		t.Fatal("owned fixture preparation not observed complete")
	}
	st, err := os.Lstat(path)
	if err != nil || !st.Mode().IsRegular() || st.Size() <= 0 || st.Size() > 65536 {
		t.Fatal("fixture assembly unavailable or oversized")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(raw)
	digest := hex.EncodeToString(sum[:])
	base := os.Getenv("WOOTC_NATIVE_QUERY_PROOF_DIR")
	if base == "" {
		t.Fatal("private proof directory required")
	}
	prefix := filepath.Join(base, t.Name())
	if err = os.MkdirAll(filepath.Dir(prefix), 0700); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(prefix+".warm.stderr.raw", session.stderr.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	record, _ := json.Marshal(map[string]any{"schemaVersion": 1, "fixturePreparationMilliseconds": time.Since(session.started).Milliseconds(), "fixturePreparationBoundMilliseconds": 10000, "observationDeadlineMilliseconds": 5000, "assemblySha256": digest, "assemblySize": len(raw), "parentExited": session.exited, "jobDrained": session.drained, "streamsDrained": session.streamsJoined, "exitCode": session.exitCode, "scope": "owned synthetic fixture preparation; no storage or protector mutation"})
	if err = os.WriteFile(prefix+".warm.json", record, 0600); err != nil {
		t.Fatal(err)
	}
	return path, digest
}

// readerOnly deliberately removes strings.Reader/bytes.Reader WriterTo. Both
// io.Copy dispatch paths must invoke the bounded writer, never Buffer.ReadFrom.
type nativeStorageReaderOnly struct{ io.Reader }

func TestNativeConfigurationBoundedOutputCopiesRefuseOverflow(t *testing.T) {
	for _, writerTo := range []bool{false, true} {
		var output boundedNativeOutput
		if _, ok := any(&output).(io.ReaderFrom); ok {
			t.Fatal("unbounded ReaderFrom exposed")
		}
		var input io.Reader = bytes.NewReader(bytes.Repeat([]byte("x"), 70000))
		if !writerTo {
			input = nativeStorageReaderOnly{input}
		}
		_, err := io.Copy(&output, input)
		if err == nil || output.Len() > 64*1024 {
			t.Fatal("io.Copy bypassed bounded output")
		}
	}
}
