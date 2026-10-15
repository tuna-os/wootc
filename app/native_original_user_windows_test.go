//go:build windows

package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func TestNativeOriginalUserRejectsMissingClosedOrAlternativeAdministrator(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	alternative := *peer
	alternative.userSID = "S-1-5-21-1-2-3-9999"
	for _, test := range []struct {
		name           string
		source, engine *nativeProcessPeer
	}{
		{"missing-source", nil, peer}, {"missing-engine", peer, nil}, {"alternative-admin", peer, &alternative},
	} {
		t.Run(test.name, func(t *testing.T) {
			if user, err := captureNativeOriginalUser(test.source, test.engine); err == nil {
				user.close()
				t.Fatal("unbound original user accepted")
			}
		})
	}
	closed := *peer
	closed.handle = 0
	if user, err := captureNativeOriginalUser(&closed, peer); err == nil {
		user.close()
		t.Fatal("closed source accepted")
	}
}

func TestNativeOriginalUserCannotReplaceObservedTokenWithPeerFields(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	// Both objects agree with each other, but disagree with the actual token.
	// An authorization object must derive identity from the retained token again.
	source, engine := *peer, *peer
	source.sessionID, engine.sessionID = 1, 1
	source.userSID, engine.userSID = "S-1-5-21-1-2-3-9999", "S-1-5-21-1-2-3-9999"
	engine.elevated = true
	if user, err := captureNativeOriginalUser(&source, &engine); err == nil {
		user.close()
		t.Fatal("wire-like peer claims replaced source token")
	}
}

func TestNativeOriginalUserActualTokenProfileAndBindingReadOnly(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	var token windows.Token
	if err := windows.OpenProcessToken(peer.handle, windows.TOKEN_QUERY|windows.TOKEN_IMPERSONATE|windows.TOKEN_DUPLICATE, &token); err != nil {
		t.Fatal(err)
	}
	defer token.Close()
	stats, err := observeNativeOriginalTokenStatistics(token)
	if err != nil {
		t.Fatal(err)
	}
	captured := &nativeOriginalUser{token: token, source: peer, statistics: stats}
	if err := captured.revalidateToken(); err != nil {
		t.Fatal(err)
	}
	t.Setenv("USERPROFILE", `Z:\untrusted-environment-profile`)
	profile, err := token.GetUserProfileDirectory()
	if err != nil {
		t.Fatal(err)
	}
	known, err := token.KnownFolderPath(windows.FOLDERID_Profile, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !filepath.IsAbs(profile) || !strings.EqualFold(filepath.Clean(profile), filepath.Clean(known)) || strings.Contains(profile, "untrusted-environment-profile") {
		t.Fatal("actual token profile binding refused")
	}
	captured.statistics.ModifiedID.LowPart++
	if captured.revalidateToken() == nil {
		t.Fatal("changed token security context accepted")
	}
}

func TestNativeOriginalUserActualInteractiveCapture(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	user, err := captureNativeOriginalUser(peer, peer)
	if err != nil {
		t.Fatal(err)
	}
	defer user.close()
	if user.sid != peer.userSID || user.session != peer.sessionID || !filepath.IsAbs(user.profile) || len(user.folders) != 6 {
		t.Fatal("actual interactive capture incomplete")
	}
	if err := user.revalidateToken(); err != nil {
		t.Fatal(err)
	}
}

func TestNativeOriginalUserActualRestrictedInteractiveCriterion(t *testing.T) {
	const flag = "WOOTC_ORIGINAL_RESTRICTED_CHILD"
	if nonce := os.Getenv(flag); nonce != "" {
		if len(nonce) != 32 || strings.Trim(nonce, "0123456789abcdef") != "" {
			t.Fatal("invalid private child correlation")
		}
		pid, err := strconv.ParseUint(os.Getenv("WOOTC_ORIGINAL_PARENT_PID"), 10, 32)
		if err != nil || int(pid) != os.Getppid() {
			t.Fatal("private child parent differs")
		}
		source, err := observeNativeProcessPeer(uint32(os.Getpid()))
		if err != nil {
			t.Fatal(err)
		}
		defer source.close()
		engine, err := observeNativeProcessPeer(uint32(pid))
		if err != nil {
			t.Fatal(err)
		}
		defer engine.close()
		var token windows.Token
		if err := windows.OpenProcessToken(source.handle, windows.TOKEN_QUERY, &token); err != nil {
			t.Fatal(err)
		}
		defer token.Close()
		groups, err := token.GetTokenGroups()
		if err != nil {
			t.Fatal(err)
		}
		restricted := false
		for _, group := range groups.AllGroups() {
			if group.Sid.IsWellKnown(windows.WinInteractiveSid) {
				restricted = group.Attributes&windows.SE_GROUP_ENABLED == 0 && group.Attributes&windows.SE_GROUP_USE_FOR_DENY_ONLY != 0
			}
		}
		if !restricted || source.sessionID == 0 || source.sessionID != engine.sessionID || source.userSID != engine.userSID || !engine.elevated {
			t.Fatal("actual restricted token context not observed")
		}
		user, err := captureNativeOriginalUser(source, engine)
		if err == nil {
			user.close()
			t.Fatal("restricted interactive SID authorized capture")
		}
		if err.Error() != "original user interactive logon required" {
			t.Fatal("actual restricted-group criterion not reached")
		}
		record, _ := json.Marshal(map[string]any{"schemaVersion": 1, "nonce": nonce, "pid": os.Getpid(), "parentPID": pid, "restrictedInteractive": true, "refused": true})
		fmt.Println("owned-restricted-token-receipt=" + string(record))
		return
	}
	var token windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY|windows.TOKEN_DUPLICATE|windows.TOKEN_ASSIGN_PRIMARY, &token); err != nil {
		t.Fatal(err)
	}
	defer token.Close()
	sid, err := windows.CreateWellKnownSid(windows.WinInteractiveSid)
	if err != nil {
		t.Fatal(err)
	}
	disabled := windows.SIDAndAttributes{Sid: sid}
	var restricted windows.Token
	proc := windows.NewLazySystemDLL("advapi32.dll").NewProc("CreateRestrictedToken")
	result, _, callErr := proc.Call(uintptr(token), 0, 1, uintptr(unsafe.Pointer(&disabled)), 0, 0, 0, 0, uintptr(unsafe.Pointer(&restricted)))
	if result == 0 {
		t.Fatal(callErr)
	}
	defer restricted.Close()
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		t.Fatal(err)
	}
	nonce := hex.EncodeToString(random[:])
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, executable, "-test.run=^TestNativeOriginalUserActualRestrictedInteractiveCriterion$", "-test.count=1", "-test.v")
	for _, v := range os.Environ() {
		k, _, _ := strings.Cut(v, "=")
		if !strings.EqualFold(k, flag) && !strings.EqualFold(k, "WOOTC_ORIGINAL_PARENT_PID") {
			command.Env = append(command.Env, v)
		}
	}
	command.Env = append(command.Env, flag+"="+nonce, "WOOTC_ORIGINAL_PARENT_PID="+strconv.Itoa(os.Getpid()))
	command.SysProcAttr = &syscall.SysProcAttr{Token: syscall.Token(restricted), HideWindow: true}
	command.WaitDelay = time.Second
	output := &nativeOriginalTestOutput{}
	command.Stdout = output
	command.Stderr = output
	if err := command.Run(); err != nil {
		t.Fatalf("owned restricted child refused: %v; %s", err, output.data)
	}
	if command.ProcessState == nil || !command.ProcessState.Exited() || command.ProcessState.ExitCode() != 0 {
		t.Fatal("owned child exit not observed")
	}
	receiptCount := 0
	for _, line := range strings.Split(string(output.data), "\n") {
		if !strings.HasPrefix(line, "owned-restricted-token-receipt=") {
			continue
		}
		var record struct {
			SchemaVersion         int
			Nonce                 string
			PID                   int
			ParentPID             uint32
			RestrictedInteractive bool
			Refused               bool
		}
		if err := json.Unmarshal([]byte(strings.TrimPrefix(line, "owned-restricted-token-receipt=")), &record); err != nil {
			t.Fatal(err)
		}
		if record.SchemaVersion != 1 || record.Nonce != nonce || record.PID != command.Process.Pid || record.ParentPID != uint32(os.Getpid()) || !record.RestrictedInteractive || !record.Refused {
			t.Fatal("owned child receipt differs")
		}
		receiptCount++
	}
	if receiptCount != 1 {
		t.Fatal("one correlated actual child observation required")
	}
}

type nativeOriginalTestOutput struct{ data []byte }

func (out *nativeOriginalTestOutput) Write(p []byte) (int, error) {
	if len(out.data)+len(p) > 4096 {
		return 0, fmt.Errorf("owned child output exceeds bound")
	}
	out.data = append(out.data, p...)
	return len(p), nil
}

func TestNativeOriginalUserActualKnownFolderCollector(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	user, err := captureNativeOriginalUser(peer, peer)
	if err != nil {
		t.Fatal(err)
	}
	defer user.close()
	t.Setenv("USERNAME", "untrusted-elevated-account")
	t.Setenv("USERPROFILE", `Z:\untrusted-environment-profile`)
	calls := 0
	sink := func(value *KnownFolders) error {
		calls++
		if value.User != filepath.Base(user.profile) || len(value.Folders) != 6 || value.CloudOnly != nil {
			t.Fatal("native collector used environment or guessed content counts")
		}
		for name, path := range value.Folders {
			if path != user.folders[name] {
				t.Fatal("native collector lost captured folder")
			}
		}
		return nil
	}
	if err := user.collectKnownFolders(sink); err != nil || calls != 1 {
		t.Fatalf("actual collector refused: %v", err)
	}
	if err := user.collectKnownFolders(func(*KnownFolders) error { return fmt.Errorf("public synthetic persistence failure") }); err == nil {
		t.Fatal("native collector swallowed persistence failure")
	}
	old := user.folders["Documents"]
	user.folders["Documents"] = `Z:\untrusted-folder`
	if err := user.collectKnownFolders(sink); err == nil || calls != 1 {
		t.Fatal("changed folder reached persistence")
	}
	user.folders["Documents"] = old
	oldStats := user.statistics
	user.statistics.ModifiedID.LowPart++
	if err := user.collectKnownFolders(sink); err == nil || calls != 1 {
		t.Fatal("changed token reached persistence")
	}
	user.statistics = oldStats
	user.close()
	if err := user.collectKnownFolders(sink); err == nil || calls != 1 {
		t.Fatal("closed capture reached persistence")
	}
}

func TestNativeOriginalUserActualOneShotInstallConsent(t *testing.T) {
	peer, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer peer.close()
	user, err := captureNativeOriginalUser(peer, peer)
	if err != nil {
		t.Fatal(err)
	}
	defer user.close()
	session := "0123456789abcdef0123456789abcdef"
	config := InstallConfig{ImageRef: "public-component-fixture", Password: "public synthetic fixture password", SessionConsent: map[string]bool{"fixture": true}}
	actions := 0
	prepare := func() *nativeInstallAuthorization {
		authority, err := prepareNativeInstallAuthorization(user, session, "wootc", config, func(InstallConfig) error { return nil }, func() error { return nil })
		if err != nil {
			t.Fatal(err)
		}
		return authority
	}
	encode := func(authority *nativeInstallAuthorization) []byte {
		data, err := json.Marshal(nativeInstallConfirmation{Kind: "confirm-install", ProtocolVersion: 1, Session: session, BrandID: "wootc", IntentID: authority.intent})
		if err != nil {
			t.Fatal(err)
		}
		return data
	}
	action := func(actual InstallConfig) error {
		actions++
		if actual.ImageRef != config.ImageRef || actual.Password != config.Password || !actual.SessionConsent["fixture"] {
			t.Fatal("immutable prepared config changed")
		}
		return nil
	}
	t.Run("actual-capture-immutable-config", func(t *testing.T) {
		authority := prepare()
		data := encode(authority)
		config.SessionConsent["fixture"] = false
		if err := authority.confirm(data, action); err != nil {
			t.Fatal(err)
		}
		config.SessionConsent["fixture"] = true
		if err := authority.confirm(data, action); err == nil || actions != 1 {
			t.Fatal("successful intent replayed")
		}
	})
	for _, name := range []string{"wrong-session", "wrong-brand", "wrong-intent", "assessment-purpose", "unknown-config", "duplicate", "case-variant", "case-semantic-duplicate", "case-semantic-duplicate-reversed", "trailing", "missing", "malformed", "oversized"} {
		t.Run(name, func(t *testing.T) {
			authority := prepare()
			correct := encode(authority)
			data := append([]byte(nil), correct...)
			switch name {
			case "wrong-session":
				data = bytes.Replace(data, []byte(session), []byte("ffffffffffffffffffffffffffffffff"), 1)
			case "wrong-brand":
				data = bytes.Replace(data, []byte(`"wootc"`), []byte(`"foreign"`), 1)
			case "wrong-intent":
				data = bytes.Replace(data, []byte(authority.intent), []byte("ffffffffffffffffffffffffffffffff"), 1)
			case "assessment-purpose":
				data = bytes.Replace(data, []byte("confirm-install"), []byte("assessment"), 1)
			case "unknown-config":
				data = append(append([]byte(nil), data[:len(data)-1]...), []byte(`,"password":"public synthetic replacement"}`)...)
			case "duplicate":
				data = append(append([]byte(nil), data[:len(data)-1]...), []byte(`,"intentId":"ffffffffffffffffffffffffffffffff"}`)...)
			case "case-variant":
				data = bytes.Replace(data, []byte(`"intentId"`), []byte(`"IntentId"`), 1)
			case "case-semantic-duplicate":
				data = bytes.Replace(data, []byte(`"kind":"confirm-install"`), []byte(`"kind":"wrong-purpose","Kind":"confirm-install"`), 1)
			case "case-semantic-duplicate-reversed":
				data = bytes.Replace(data, []byte(`"kind":"confirm-install"`), []byte(`"Kind":"wrong-purpose","kind":"confirm-install"`), 1)
			case "trailing":
				data = append(data, []byte(`{}`)...)
			case "missing":
				data = []byte(`{}`)
			case "malformed":
				data = []byte(`{"kind":`)
			case "oversized":
				data = bytes.Repeat([]byte(" "), 4097)
			}
			before := actions
			if authority.confirm(data, action) == nil || actions != before {
				t.Fatal("invalid confirmation invoked operation")
			}
			if authority.confirm(correct, action) == nil || actions != before {
				t.Fatal("invalid attempt retained reusable intent")
			}
		})
	}
	t.Run("changed-observation", func(t *testing.T) {
		authority := prepare()
		data := encode(authority)
		authority.revalidate = func() error { return fmt.Errorf("public synthetic volume swap") }
		before := actions
		if authority.confirm(data, action) == nil || actions != before {
			t.Fatal("changed observation invoked operation")
		}
	})
	t.Run("changed-token", func(t *testing.T) {
		authority := prepare()
		data := encode(authority)
		stats := user.statistics
		user.statistics.ModifiedID.LowPart++
		defer func() { user.statistics = stats }()
		before := actions
		if authority.confirm(data, action) == nil || actions != before {
			t.Fatal("changed original token invoked operation")
		}
	})
	t.Run("operation-failure-consumed", func(t *testing.T) {
		authority := prepare()
		data := encode(authority)
		calls := 0
		fail := func(InstallConfig) error { calls++; return fmt.Errorf("public synthetic operation refusal") }
		if authority.confirm(data, fail) == nil || authority.confirm(data, fail) == nil || calls != 1 {
			t.Fatal("failed operation retained reusable intent")
		}
	})
	t.Run("reentrant-refuses", func(t *testing.T) {
		authority := prepare()
		data := encode(authority)
		if authority.confirm(data, func(InstallConfig) error {
			if authority.confirm(data, action) == nil {
				t.Fatal("reentrant attempt accepted")
			}
			return nil
		}) != nil {
			t.Fatal("outer confirmed action refused")
		}
	})
	if _, err := prepareNativeInstallAuthorization(user, session, "wootc", config, nil, func() error { return nil }); err == nil {
		t.Fatal("absent configuration validator granted intent")
	}
	if _, err := prepareNativeInstallAuthorization(user, session, "wootc", config, func(InstallConfig) error { return nil }, nil); err == nil {
		t.Fatal("absent observation validator granted intent")
	}
}

// Alternative-administrator topology with real accounts: this elevated test
// process plays the engine; a disposable standard user (created by
// tests/native_original_user_controls.py) runs the pipe client in this same
// interactive session through the Secondary Logon service. The captured
// identity, profile and known folders must be that user's, never the
// engine's. A client that allows only Identification must be refused.
func TestNativeOriginalUserActualAlternativeAdministratorPipe(t *testing.T) {
	name, secret, sid := os.Getenv("WOOTC_ORIGINAL_ALT_USER"), os.Getenv("WOOTC_ORIGINAL_ALT_PASSWORD"), os.Getenv("WOOTC_ORIGINAL_ALT_SID")
	if name == "" || secret == "" || sid == "" {
		// The control script requires this test to pass, so a skip there fails.
		t.Skip("disposable standard-user fixture required; run tests/native_original_user_controls.py")
	}
	engine, err := observeNativeProcessPeer(uint32(os.Getpid()))
	if err != nil {
		t.Fatal(err)
	}
	defer engine.close()
	if !engine.elevated || engine.userSID == sid {
		t.Fatal("engine must be an elevated, different administrator")
	}
	var engineToken windows.Token
	if err := windows.OpenProcessToken(windows.CurrentProcess(), windows.TOKEN_QUERY, &engineToken); err != nil {
		t.Fatal(err)
	}
	engineProfile, err := engineToken.GetUserProfileDirectory()
	engineToken.Close()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("USERPROFILE", engineProfile)
	t.Setenv("USERNAME", "engine-administrator")

	t.Run("impersonation", func(t *testing.T) {
		user, source, cleanup := nativeAlternativeClient(t, engine, name, secret, "Impersonation")
		defer cleanup()
		if user == nil {
			t.Fatal("alternative-admin capture refused")
		}
		defer user.close()
		if user.sid != sid || source.userSID != sid || user.sid == engine.userSID || user.session != engine.sessionID {
			t.Fatal("captured identity is not the original standard user")
		}
		if strings.EqualFold(user.profile, filepath.Clean(engineProfile)) || !filepath.IsAbs(user.profile) {
			t.Fatal("captured profile is the engine administrator's")
		}
		var written *KnownFolders
		if err := user.collectKnownFolders(func(value *KnownFolders) error { written = value; return nil }); err != nil {
			t.Fatalf("original-user collection refused: %v", err)
		}
		if written == nil || written.User != filepath.Base(user.profile) || strings.EqualFold(written.User, filepath.Base(engineProfile)) || len(written.Folders) != 6 {
			t.Fatal("collection does not belong to the original user")
		}
		for folder, path := range written.Folders {
			inOriginal := strings.HasPrefix(strings.ToLower(path), strings.ToLower(user.profile)+`\`)
			inEngine := strings.HasPrefix(strings.ToLower(path), strings.ToLower(filepath.Clean(engineProfile))+`\`)
			if !inOriginal || inEngine {
				t.Fatalf("%s resolved outside the original user's profile: %s", folder, path)
			}
		}
		record, _ := json.Marshal(map[string]any{"schemaVersion": 1, "originalSid": user.sid, "engineSid": engine.userSID, "session": user.session, "originalProfileBase": filepath.Base(user.profile), "engineProfileBase": filepath.Base(engineProfile), "folders": len(written.Folders)})
		fmt.Println("alternative-admin-original-user=" + string(record))
		if err := user.revalidateToken(); err != nil {
			t.Fatal(err)
		}
		cleanup()
		if user.revalidateToken() == nil {
			t.Fatal("capture survived the original user's process exit")
		}
	})
	t.Run("identification-only", func(t *testing.T) {
		user, _, cleanup := nativeAlternativeClient(t, engine, name, secret, "Identification")
		defer cleanup()
		if user != nil {
			user.close()
			t.Fatal("identification-only client authorized original-user capture")
		}
	})
}

// nativeAlternativeClient starts powershell.exe as the standard user, serves
// one authenticated preview pipe to it and returns the bridge's capture (nil
// when refused). The client allows the requested impersonation level only.
func nativeAlternativeClient(t *testing.T, engine *nativeProcessPeer, name, secret, level string) (*nativeOriginalUser, *nativeProcessPeer, func()) {
	t.Helper()
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		t.Fatal(err)
	}
	session := hex.EncodeToString(random[:])
	pipeName := `wootc-preview-` + session
	script := "$ErrorActionPreference='Stop';" +
		"$p=[IO.Pipes.NamedPipeClientStream]::new('.','" + pipeName + "',[IO.Pipes.PipeAccessRights]0x0012019b,[IO.Pipes.PipeOptions]::None,[Security.Principal.TokenImpersonationLevel]::" + level + ",[IO.HandleInheritability]::None);" +
		"$p.Connect(30000);$p.WriteByte(10);$p.Flush();$null=$p.ReadByte();$p.Dispose()"
	system32, err := windows.GetSystemDirectory()
	if err != nil {
		t.Fatal(err)
	}
	command, err := windows.UTF16FromString(`"` + filepath.Join(system32, `WindowsPowerShell\v1.0\powershell.exe`) + `" -NoLogo -NoProfile -NonInteractive -Command "` + script + `"`)
	if err != nil {
		t.Fatal(err)
	}
	user16, _ := windows.UTF16PtrFromString(name)
	domain16, _ := windows.UTF16PtrFromString(".")
	secret16, _ := windows.UTF16PtrFromString(secret)
	directory16, _ := windows.UTF16PtrFromString(system32)
	startup := windows.StartupInfo{Cb: uint32(unsafe.Sizeof(windows.StartupInfo{})), Flags: windows.STARTF_USESHOWWINDOW, ShowWindow: windows.SW_HIDE}
	var process windows.ProcessInformation
	logon := windows.NewLazySystemDLL("advapi32.dll").NewProc("CreateProcessWithLogonW")
	const logonWithProfile, createNoWindow = 1, 0x08000000
	ok, _, callErr := logon.Call(uintptr(unsafe.Pointer(user16)), uintptr(unsafe.Pointer(domain16)), uintptr(unsafe.Pointer(secret16)), logonWithProfile, 0,
		uintptr(unsafe.Pointer(&command[0])), createNoWindow, 0, uintptr(unsafe.Pointer(directory16)), uintptr(unsafe.Pointer(&startup)), uintptr(unsafe.Pointer(&process)))
	if ok == 0 {
		t.Fatalf("standard-user client launch refused: %v", callErr)
	}
	windows.CloseHandle(process.Thread)
	var pipe windows.Handle = windows.InvalidHandle
	var connection *os.File
	var source *nativeProcessPeer
	done := false
	cleanup := func() {
		if done {
			return
		}
		done = true
		if connection != nil {
			connection.Close()
		} else if pipe != windows.InvalidHandle {
			windows.CloseHandle(pipe)
		}
		if state, _ := windows.WaitForSingleObject(process.Process, 30000); state != windows.WAIT_OBJECT_0 {
			windows.TerminateProcess(process.Process, 1)
			windows.WaitForSingleObject(process.Process, 5000)
		}
		windows.CloseHandle(process.Process)
		if source != nil {
			source.close()
		}
	}
	source, err = observeNativeProcessPeer(process.ProcessId)
	if err != nil {
		cleanup()
		t.Fatalf("engine could not observe the standard-user client: %v", err)
	}
	pipe, err = createNativePipe(`\\.\pipe\`+pipeName, source)
	if err != nil {
		cleanup()
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	err = connectNativePipe(ctx, pipe)
	cancel()
	if err != nil {
		cleanup()
		t.Fatalf("standard-user client did not connect: %v", err)
	}
	connection = os.NewFile(uintptr(pipe), pipeName)
	if err := connection.SetDeadline(time.Now().Add(15 * time.Second)); err != nil {
		cleanup()
		t.Fatal(err)
	}
	var first [1]byte
	if _, err := connection.Read(first[:]); err != nil || first[0] != 10 {
		cleanup()
		t.Fatalf("client data required before impersonation: %v", err)
	}
	if level == "Impersonation" {
		if err := verifyNativePipeClient(pipe, source); err != nil {
			cleanup()
			t.Fatal(err)
		}
	}
	user, err := captureNativeOriginalUserFromPipe(pipe, source, engine)
	if err != nil {
		t.Logf("capture refused: %v", err)
		user = nil
	}
	return user, source, func() {
		if connection != nil {
			connection.Write([]byte{10})
		}
		cleanup()
	}
}
