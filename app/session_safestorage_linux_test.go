//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/godbus/dbus/v5"
)

const safeStorageFixturePassword = "fixture-safe-storage-password"

// Expected bytes generated independently with Python hashlib.pbkdf2_hmac and
// OpenSSL enc -aes-128-cbc, not with the implementation under test. The derived
// key is 9c058bd8b57075cd51eb1328209d3b70. The last payload is SHA256 of the
// cookie host .example.com followed by session-token (modern cookie DB binding).
func assertLinuxSafeStorageFixtures(t *testing.T, encryptor sessionValueEncryptor) {
	t.Helper()
	fixtures := []struct{ plaintext, ciphertext string }{
		{"", ""},
		{"68656c6c6f", "7631319acee7ff700719747485f892a3534c44"},
		{"30313233343536373839616263646566", "763131cc40b62b37076cb827c16f3cdbf263db1a86a0d9a93a4a77cd95796151c92400"},
		{"00ff0180", "7631317cbdd3f4283f5017dc85d0400bd10ba1"},
		{"1496295b2be8c88d729a34163e6885b0470833c34e8b5b53c370a9f5dbb7700973657373696f6e2d746f6b656e", "763131e24a47db779e7f1f2c8e438e62da3e512fd105be46bc875ccc4c60628928d11adc93d3f4aa8e72619c0f71ce50c4a59e"},
	}
	for i, fixture := range fixtures {
		plaintext, err := hex.DecodeString(fixture.plaintext)
		if err != nil {
			t.Fatal(err)
		}
		before := bytes.Clone(plaintext)
		got, err := encryptor.Encrypt(plaintext)
		if err != nil {
			t.Fatal(err)
		}
		if hex.EncodeToString(got) != fixture.ciphertext {
			t.Errorf("fixture %d: wire format differs", i)
		}
		if !bytes.Equal(plaintext, before) {
			t.Errorf("fixture %d: mutated input", i)
		}
	}
}

func TestLinuxSafeStorageCipherFixtures(t *testing.T) {
	encryptor, err := newLinuxSafeStorageEncryptor(context.Background(), []byte(safeStorageFixturePassword))
	if err != nil {
		t.Fatal(err)
	}
	defer encryptor.(io.Closer).Close()
	assertLinuxSafeStorageFixtures(t, encryptor)
}

func TestLinuxSafeStorageCipherLifecycle(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	encryptor, err := newLinuxSafeStorageEncryptor(ctx, []byte(safeStorageFixturePassword))
	if err != nil {
		t.Fatal(err)
	}
	cancel()
	if _, err := encryptor.Encrypt([]byte("value")); !errors.Is(err, context.Canceled) {
		t.Fatal("canceled encryption accepted")
	}
	if err := encryptor.(io.Closer).Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := encryptor.Encrypt(nil); err == nil {
		t.Fatal("closed encryption accepted")
	}
	if _, err := newLinuxSafeStorageEncryptor(context.Background(), nil); !errors.Is(err, errLinuxSafeStorageIncompatible) {
		t.Fatal("empty key accepted")
	}
}

type safeStorageTestStep struct {
	path   dbus.ObjectPath
	method string
	args   []any
	reply  []any
	err    error
	hook   func([]any) []any
}

type safeStorageTestBus struct {
	t     *testing.T
	steps []safeStorageTestStep
	ctx   context.Context
}

func (b *safeStorageTestBus) Call(ctx context.Context, destination string, path dbus.ObjectPath, method string, args ...any) *dbus.Call {
	b.t.Helper()
	if ctx != b.ctx {
		b.t.Fatal("D-Bus call lost caller context")
	}
	if len(b.steps) == 0 {
		b.t.Fatalf("unexpected D-Bus method %s", method)
	}
	step := b.steps[0]
	b.steps = b.steps[1:]
	expectedDestination := ":1.42"
	if method == "org.freedesktop.DBus.GetNameOwner" {
		expectedDestination = "org.freedesktop.DBus"
	}
	if destination != expectedDestination {
		b.t.Fatal("call did not pin unique service owner")
	}
	if path != step.path || method != step.method {
		b.t.Fatalf("unexpected D-Bus call %s at %s", method, path)
	}
	if step.hook != nil {
		return &dbus.Call{Body: step.hook(args), Err: step.err}
	}
	if !reflect.DeepEqual(args, step.args) {
		b.t.Fatalf("argument types/values differ for %s", method)
	}
	return &dbus.Call{Body: step.reply, Err: step.err}
}

func newSafeStorageTestBus(t *testing.T, steps []safeStorageTestStep) *safeStorageTestBus {
	t.Helper()
	bus := &safeStorageTestBus{t: t, steps: steps, ctx: context.Background()}
	t.Cleanup(func() {
		if len(bus.steps) != 0 {
			t.Errorf("%d D-Bus calls not made", len(bus.steps))
		}
	})
	return bus
}

func safeStorageOwnerStep(name string) safeStorageTestStep {
	return safeStorageTestStep{path: "/org/freedesktop/DBus", method: "org.freedesktop.DBus.GetNameOwner", args: []any{name}, reply: []any{":1.42"}}
}

func secretTestStep(method string, args, reply []any) safeStorageTestStep {
	return safeStorageTestStep{path: secretServicePath, method: secretServiceInterface + "." + method, args: args, reply: reply}
}

func secretUnlockedStep(path dbus.ObjectPath, iface string, locked bool) safeStorageTestStep {
	return safeStorageTestStep{path: path, method: "org.freedesktop.DBus.Properties.Get", args: []any{iface, "Locked"}, reply: []any{dbus.MakeVariant(locked)}}
}

func secretSessionStep() safeStorageTestStep {
	return secretTestStep("OpenSession", []any{"plain", dbus.MakeVariant("")}, []any{dbus.MakeVariant(""), dbus.ObjectPath("/session/1")})
}

func secretCloseStep() safeStorageTestStep {
	return safeStorageTestStep{path: "/session/1", method: "org.freedesktop.Secret.Session.Close"}
}

func secretGetStep(password []byte) safeStorageTestStep {
	return safeStorageTestStep{path: "/item/1", method: secretItemInterface + ".GetSecret", args: []any{dbus.ObjectPath("/session/1")}, reply: []any{[]any{dbus.ObjectPath("/session/1"), []byte{}, password, "text/plain"}}}
}

func TestSecretServiceSafeStorageRetrieval(t *testing.T) {
	steps := []safeStorageTestStep{
		safeStorageOwnerStep(secretServiceName),
		secretTestStep("SearchItems", []any{map[string]string{"application": "chrome"}}, []any{[]dbus.ObjectPath{"/item/1"}, []dbus.ObjectPath{}}),
		secretSessionStep(),
		secretUnlockedStep("/item/1", secretItemInterface, false),
		secretGetStep([]byte(safeStorageFixturePassword)),
		secretCloseStep(),
	}
	bus := newSafeStorageTestBus(t, steps)
	identity, _ := linuxSafeStorageIdentityFor("chrome")
	encryptor, err := openLinuxSafeStorageOnBus(bus.ctx, bus, "secret-service", identity)
	if err != nil {
		t.Fatal(err)
	}
	defer encryptor.(io.Closer).Close()
	assertLinuxSafeStorageFixtures(t, encryptor)
}

func TestSecretServiceSafeStorageCreation(t *testing.T) {
	var stored []byte
	create := safeStorageTestStep{path: "/collection/default", method: secretCollectionInterface + ".CreateItem"}
	create.hook = func(args []any) []any {
		if dbus.SignatureOf(args...).String() != "a{sv}(oayays)b" {
			t.Fatal("CreateItem wire signature differs")
		}
		props := args[0].(map[string]dbus.Variant)
		if props[secretItemInterface+".Label"].Value() != "Chrome Safe Storage" {
			t.Fatal("incorrect Chromium item label")
		}
		attrs := props[secretItemInterface+".Attributes"].Value().(map[string]string)
		if !reflect.DeepEqual(attrs, map[string]string{"application": "chrome", "xdg:schema": "chrome_libsecret_os_crypt_password_v2"}) {
			t.Fatal("incorrect Chromium item attributes")
		}
		secret := args[1].(safeStorageSecret)
		if secret.Session != "/session/1" || len(secret.Parameters) != 0 || secret.ContentType != "text/plain; charset=utf8" || args[2] != false {
			t.Fatal("unsafe CreateItem arguments")
		}
		raw, err := base64.StdEncoding.DecodeString(string(secret.Value))
		if err != nil || len(raw) != 16 {
			t.Fatal("new password is not Chromium's base64-encoded 16 random bytes")
		}
		stored = bytes.Clone(secret.Value)
		return []any{dbus.ObjectPath("/item/1"), dbus.ObjectPath("/")}
	}
	get := secretGetStep(nil)
	get.hook = func(args []any) []any {
		if !reflect.DeepEqual(args, []any{dbus.ObjectPath("/session/1")}) {
			t.Fatal("incorrect GetSecret arguments")
		}
		return []any{[]any{dbus.ObjectPath("/session/1"), []byte{}, bytes.Clone(stored), "text/plain"}}
	}
	bus := newSafeStorageTestBus(t, []safeStorageTestStep{
		safeStorageOwnerStep(secretServiceName),
		secretTestStep("SearchItems", []any{map[string]string{"application": "chrome"}}, []any{[]dbus.ObjectPath{}, []dbus.ObjectPath{}}),
		secretTestStep("ReadAlias", []any{"default"}, []any{dbus.ObjectPath("/collection/default")}),
		secretUnlockedStep("/collection/default", secretCollectionInterface, false),
		secretSessionStep(), create,
		secretTestStep("SearchItems", []any{map[string]string{"application": "chrome"}}, []any{[]dbus.ObjectPath{"/item/1"}, []dbus.ObjectPath{}}),
		secretUnlockedStep("/item/1", secretItemInterface, false), get, secretCloseStep(),
	})
	identity, _ := linuxSafeStorageIdentityFor("chrome")
	encryptor, err := openLinuxSafeStorageOnBus(bus.ctx, bus, "secret-service", identity)
	if err != nil {
		t.Fatal(err)
	}
	defer encryptor.(io.Closer).Close()
	if len(stored) != 24 {
		t.Fatal("key creation did not persist password")
	}
	expected, err := newLinuxSafeStorageEncryptor(bus.ctx, stored)
	if err != nil {
		t.Fatal(err)
	}
	defer expected.(io.Closer).Close()
	left, err := encryptor.Encrypt([]byte("created-key-fixture"))
	if err != nil {
		t.Fatal(err)
	}
	right, err := expected.Encrypt([]byte("created-key-fixture"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(left, right) {
		t.Fatal("encryptor did not use stored key")
	}
}

func TestSecretServiceSafeStorageFailClosed(t *testing.T) {
	attrs := []any{map[string]string{"application": "chrome"}}
	for _, tc := range []struct {
		name  string
		steps []safeStorageTestStep
		want  error
	}{
		{"locked-item", []safeStorageTestStep{secretTestStep("SearchItems", attrs, []any{[]dbus.ObjectPath{}, []dbus.ObjectPath{"/item/1"}})}, errLinuxSafeStorageLocked},
		{"duplicate-items", []safeStorageTestStep{secretTestStep("SearchItems", attrs, []any{[]dbus.ObjectPath{"/item/1", "/item/2"}, []dbus.ObjectPath{}})}, errLinuxSafeStorageIncompatible},
		{"missing-default", []safeStorageTestStep{secretTestStep("SearchItems", attrs, []any{[]dbus.ObjectPath{}, []dbus.ObjectPath{}}), secretTestStep("ReadAlias", []any{"default"}, []any{dbus.ObjectPath("/")})}, errLinuxSafeStorageMissing},
		{"locked-default", []safeStorageTestStep{secretTestStep("SearchItems", attrs, []any{[]dbus.ObjectPath{}, []dbus.ObjectPath{}}), secretTestStep("ReadAlias", []any{"default"}, []any{dbus.ObjectPath("/collection/default")}), secretUnlockedStep("/collection/default", secretCollectionInterface, true)}, errLinuxSafeStorageLocked},
		{"item-lock-race", []safeStorageTestStep{secretTestStep("SearchItems", attrs, []any{[]dbus.ObjectPath{"/item/1"}, []dbus.ObjectPath{}}), secretSessionStep(), secretUnlockedStep("/item/1", secretItemInterface, true), secretCloseStep()}, errLinuxSafeStorageLocked},
		{"empty-secret", []safeStorageTestStep{secretTestStep("SearchItems", attrs, []any{[]dbus.ObjectPath{"/item/1"}, []dbus.ObjectPath{}}), secretSessionStep(), secretUnlockedStep("/item/1", secretItemInterface, false), secretGetStep([]byte{}), secretCloseStep()}, errLinuxSafeStorageIncompatible},
		{"creation-prompt", []safeStorageTestStep{
			secretTestStep("SearchItems", attrs, []any{[]dbus.ObjectPath{}, []dbus.ObjectPath{}}),
			secretTestStep("ReadAlias", []any{"default"}, []any{dbus.ObjectPath("/collection/default")}),
			secretUnlockedStep("/collection/default", secretCollectionInterface, false), secretSessionStep(),
			{path: "/collection/default", method: secretCollectionInterface + ".CreateItem", hook: func(args []any) []any { return []any{dbus.ObjectPath("/"), dbus.ObjectPath("/prompt/1")} }},
			secretCloseStep(),
		}, errLinuxSafeStorageLocked},
	} {
		t.Run(tc.name, func(t *testing.T) {
			steps := append([]safeStorageTestStep{safeStorageOwnerStep(secretServiceName)}, tc.steps...)
			bus := newSafeStorageTestBus(t, steps)
			identity, _ := linuxSafeStorageIdentityFor("chrome")
			if _, err := openLinuxSafeStorageOnBus(bus.ctx, bus, "secret-service", identity); !errors.Is(err, tc.want) {
				t.Fatalf("wrong fail-closed error: %v", err)
			}
		})
	}
}

func TestLinuxSafeStorageSelectionAndRedaction(t *testing.T) {
	for _, application := range []string{"spotify", "edge", "chromium", "", "Chrome"} {
		if _, err := openLinuxSafeStorage(context.Background(), "secret-service", application); !errors.Is(err, errLinuxSafeStorageIncompatible) {
			t.Fatalf("unverified application %q accepted", application)
		}
	}
	for _, backend := range []string{"", "auto", "basic", "gnome", "kwallet", "plaintext"} {
		if _, err := openLinuxSafeStorage(context.Background(), backend, "chrome"); !errors.Is(err, errLinuxSafeStorageIncompatible) {
			t.Fatalf("implicit/unsupported backend %q accepted", backend)
		}
	}
	t.Setenv("DBUS_SESSION_BUS_ADDRESS", "")
	if _, err := openLinuxSafeStorage(context.Background(), "secret-service", "chrome"); !errors.Is(err, errLinuxSafeStorageUnavailable) {
		t.Fatal("missing session bus accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := openLinuxSafeStorage(ctx, "secret-service", "chrome"); !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation lost")
	}
	step := safeStorageOwnerStep(secretServiceName)
	step.err = errors.New("secret contents must not be returned")
	bus := newSafeStorageTestBus(t, []safeStorageTestStep{step})
	identity, _ := linuxSafeStorageIdentityFor("chrome")
	_, err := openLinuxSafeStorageOnBus(bus.ctx, bus, "secret-service", identity)
	if !errors.Is(err, errLinuxSafeStorageUnavailable) || strings.Contains(err.Error(), "secret contents") {
		t.Fatal("service error was not safely redacted")
	}
}

// Opt in only in a disposable user session: this may CREATE the real Chrome
// safe-storage key. Start/unlock the selected daemon externally; the adapter
// never does so. Set WOOTC_SAFESTORAGE_LIVE to secret-service/kwallet5/kwallet6,
// WOOTC_SAFESTORAGE_LIVE_DISPOSABLE=1, and WOOTC_SAFESTORAGE_LIVE_STATE to
// unlocked, locked, missing or unavailable. Run each state in a separate fresh
// dbus-run-session fixture. An unlocked fixture with no Chrome key exercises
// creation followed by retrieval. No live browser/service authentication is
// established by this keyring-only test.
func TestLinuxSafeStorageLive(t *testing.T) {
	backend := os.Getenv("WOOTC_SAFESTORAGE_LIVE")
	if backend == "" {
		t.Skip("opt-in disposable D-Bus session required")
	}
	if os.Getenv("WOOTC_SAFESTORAGE_LIVE_DISPOSABLE") != "1" {
		t.Fatal("refusing to touch a non-disposable keyring")
	}
	state := os.Getenv("WOOTC_SAFESTORAGE_LIVE_STATE")
	wantErrors := map[string]error{"locked": errLinuxSafeStorageLocked, "missing": errLinuxSafeStorageMissing, "unavailable": errLinuxSafeStorageUnavailable}
	if state != "unlocked" && wantErrors[state] == nil {
		t.Fatal("explicit expected live keyring state required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	first, err := openLinuxSafeStorage(ctx, backend, "chrome")
	if state != "unlocked" {
		if !errors.Is(err, wantErrors[state]) {
			t.Fatalf("expected %s keyring error, got %v", state, err)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	defer first.(io.Closer).Close()
	second, err := openLinuxSafeStorage(ctx, backend, "chrome")
	if err != nil {
		t.Fatal(err)
	}
	defer second.(io.Closer).Close()
	left, err := first.Encrypt([]byte("keyring-only-live-fixture"))
	if err != nil {
		t.Fatal(err)
	}
	right, err := second.Encrypt([]byte("keyring-only-live-fixture"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(left, right) || !bytes.HasPrefix(left, []byte("v11")) {
		t.Fatal("live key retrieval is not stable")
	}
	if (len(left)-3)%aes.BlockSize != 0 {
		t.Fatal("live ciphertext is not block-aligned")
	}
	// Decrypt with the independently reopened key handle, not the first
	// encryptor. This is a keyring round trip, not service-token acceptance.
	payload := bytes.Clone(left[3:])
	cipher.NewCBCDecrypter(second.(*linuxSafeStorageEncryptor).block, bytes.Repeat([]byte{' '}, aes.BlockSize)).CryptBlocks(payload, payload)
	padding := int(payload[len(payload)-1])
	if padding < 1 || padding > aes.BlockSize || !bytes.Equal(payload[len(payload)-padding:], bytes.Repeat([]byte{byte(padding)}, padding)) {
		t.Fatal("live ciphertext has invalid padding")
	}
	if !bytes.Equal(payload[:len(payload)-padding], []byte("keyring-only-live-fixture")) {
		t.Fatal("live keyring encryption round trip differs")
	}
}
