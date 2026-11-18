//go:build linux

package main

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"errors"
	"os"
	"strings"
	"sync"

	"github.com/godbus/dbus/v5"
	"golang.org/x/crypto/pbkdf2"
)

// These adapters implement Chromium 134's components/os_crypt/sync/{os_crypt_linux,
// key_storage_linux,key_storage_libsecret,key_storage_kwallet}.cc. The caller
// selects the target's actual backend; a desktop name is not evidence of that
// choice. In particular, basic_text/v10 is never a fallback here.
type sessionValueEncryptor interface {
	Encrypt([]byte) ([]byte, error)
}

var (
	errLinuxSafeStorageUnavailable  = errors.New("Linux safeStorage service unavailable or access denied")
	errLinuxSafeStorageLocked       = errors.New("Linux safeStorage collection or wallet is locked")
	errLinuxSafeStorageMissing      = errors.New("Linux safeStorage default collection or wallet is missing")
	errLinuxSafeStorageIncompatible = errors.New("Linux safeStorage identity or key is incompatible")
)

const (
	secretServiceName                         = "org.freedesktop.secrets"
	secretServicePath         dbus.ObjectPath = "/org/freedesktop/secrets"
	secretServiceInterface                    = "org.freedesktop.Secret.Service"
	secretItemInterface                       = "org.freedesktop.Secret.Item"
	secretCollectionInterface                 = "org.freedesktop.Secret.Collection"
	secretSchema                              = "chrome_libsecret_os_crypt_password_v2"
)

type linuxSafeStorageIdentity struct {
	application       string
	label             string
	folder            string
	walletApplication string
}

func linuxSafeStorageIdentityFor(application string) (linuxSafeStorageIdentity, error) {
	switch application {
	case "chrome":
		return linuxSafeStorageIdentity{"chrome", "Chrome Safe Storage", "Chrome Keys", "Google Chrome"}, nil
	case "spotify":
		// Spotify is not a stock Electron build. Enabling this requires a
		// versioned Linux Spotify fixture proving its selected backend,
		// application attribute / wallet folder, key, appid and value format.
		// A guessed "spotify" attribute can create an unrelated, unusable key.
		return linuxSafeStorageIdentity{}, errLinuxSafeStorageIncompatible
	default:
		return linuxSafeStorageIdentity{}, errLinuxSafeStorageIncompatible
	}
}

// safeStorageBus is the injectable wire boundary. Implementations must disable
// D-Bus service activation; production calls also pin the service's unique owner.
type safeStorageBus interface {
	Call(context.Context, string, dbus.ObjectPath, string, ...any) *dbus.Call
}

type safeStorageDBus struct{ conn *dbus.Conn }

func (b safeStorageDBus) Call(ctx context.Context, destination string, path dbus.ObjectPath, method string, args ...any) *dbus.Call {
	return b.conn.Object(destination, path).CallWithContext(ctx, method, dbus.FlagNoAutoStart, args...)
}

func openLinuxSafeStorage(ctx context.Context, backend string, application string) (sessionValueEncryptor, error) {
	identity, err := linuxSafeStorageIdentityFor(application)
	if err != nil {
		return nil, err
	}
	if backend != "secret-service" && backend != "kwallet5" && backend != "kwallet6" {
		return nil, errLinuxSafeStorageIncompatible
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	// Do not use SessionBus(): its address discovery can auto-launch a bus.
	// The importer must already be in the installed user's graphical session.
	address := os.Getenv("DBUS_SESSION_BUS_ADDRESS")
	if address == "" {
		return nil, errLinuxSafeStorageUnavailable
	}
	conn, err := dbus.Dial(address, dbus.WithContext(ctx))
	if err != nil {
		return nil, safeStorageCallError(ctx)
	}
	defer conn.Close()
	if conn.Auth(nil) != nil || conn.Hello() != nil {
		return nil, safeStorageCallError(ctx)
	}
	return openLinuxSafeStorageOnBus(ctx, safeStorageDBus{conn}, backend, identity)
}

func openLinuxSafeStorageOnBus(ctx context.Context, bus safeStorageBus, backend string, identity linuxSafeStorageIdentity) (sessionValueEncryptor, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var password []byte
	var err error
	switch backend {
	case "secret-service":
		password, err = readSecretServicePassword(ctx, bus, identity)
	case "kwallet5", "kwallet6":
		password, err = readKWalletPassword(ctx, bus, backend, identity)
	default:
		return nil, errLinuxSafeStorageIncompatible
	}
	defer clear(password)
	if err != nil {
		return nil, err
	}
	return newLinuxSafeStorageEncryptor(ctx, password)
}

// Never include service-supplied error text: a malicious or buggy service may
// embed secrets or token material in a D-Bus error response.
func safeStorageCallError(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return errLinuxSafeStorageUnavailable
}

func safeStorageOwner(ctx context.Context, bus safeStorageBus, name string) (string, error) {
	var owner string
	if bus.Call(ctx, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.GetNameOwner", name).Store(&owner) != nil {
		return "", safeStorageCallError(ctx)
	}
	if !strings.HasPrefix(owner, ":") {
		return "", errLinuxSafeStorageUnavailable
	}
	return owner, nil
}

func safeStorageUnlocked(ctx context.Context, bus safeStorageBus, owner string, path dbus.ObjectPath, iface string) error {
	var locked dbus.Variant
	if bus.Call(ctx, owner, path, "org.freedesktop.DBus.Properties.Get", iface, "Locked").Store(&locked) != nil {
		return safeStorageCallError(ctx)
	}
	value, ok := locked.Value().(bool)
	if !ok {
		return errLinuxSafeStorageIncompatible
	}
	if value {
		return errLinuxSafeStorageLocked
	}
	return nil
}

// Secret Service's Secret wire type is (oayays), not a byte array or string.
type safeStorageSecret struct {
	Session     dbus.ObjectPath
	Parameters  []byte
	Value       []byte
	ContentType string
}

func readSecretServicePassword(ctx context.Context, bus safeStorageBus, identity linuxSafeStorageIdentity) ([]byte, error) {
	owner, err := safeStorageOwner(ctx, bus, secretServiceName)
	if err != nil {
		return nil, err
	}
	attrs := map[string]string{"application": identity.application}
	var unlocked, locked []dbus.ObjectPath
	if bus.Call(ctx, owner, secretServicePath, secretServiceInterface+".SearchItems", attrs).Store(&unlocked, &locked) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if len(locked) != 0 {
		return nil, errLinuxSafeStorageLocked
	}
	if len(unlocked) > 1 {
		// Do not pick a possibly unrelated duplicate key or overwrite it.
		return nil, errLinuxSafeStorageIncompatible
	}
	var collection dbus.ObjectPath
	if len(unlocked) == 0 {
		if bus.Call(ctx, owner, secretServicePath, secretServiceInterface+".ReadAlias", "default").Store(&collection) != nil {
			return nil, safeStorageCallError(ctx)
		}
		if collection == "/" || !collection.IsValid() {
			return nil, errLinuxSafeStorageMissing
		}
		if err := safeStorageUnlocked(ctx, bus, owner, collection, secretCollectionInterface); err != nil {
			return nil, err
		}
	}
	var output dbus.Variant
	var session dbus.ObjectPath
	// "plain" is a Secret Service session algorithm on the user's D-Bus,
	// not Chromium's basic_text fallback. No secret is written to disk here.
	if bus.Call(ctx, owner, secretServicePath, secretServiceInterface+".OpenSession", "plain", dbus.MakeVariant("")).Store(&output, &session) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if session == "/" || !session.IsValid() {
		return nil, errLinuxSafeStorageIncompatible
	}
	defer bus.Call(ctx, owner, session, "org.freedesktop.Secret.Session.Close")
	var item dbus.ObjectPath
	if len(unlocked) == 1 {
		item = unlocked[0]
	} else {
		password, err := randomSafeStoragePassword()
		if err != nil {
			return nil, err
		}
		defer clear(password)
		properties := map[string]dbus.Variant{
			secretItemInterface + ".Label": dbus.MakeVariant(identity.label),
			secretItemInterface + ".Attributes": dbus.MakeVariant(map[string]string{
				"application": identity.application,
				"xdg:schema":  secretSchema,
			}),
		}
		var prompt dbus.ObjectPath
		secret := safeStorageSecret{session, []byte{}, password, "text/plain; charset=utf8"}
		// Never replace an existing key, and never execute a returned prompt.
		if bus.Call(ctx, owner, collection, secretCollectionInterface+".CreateItem", properties, secret, false).Store(&item, &prompt) != nil {
			return nil, safeStorageCallError(ctx)
		}
		if prompt != "/" {
			return nil, errLinuxSafeStorageLocked
		}
		// Detect concurrent creation rather than returning a key Chromium may
		// not choose. Searches intentionally omit xdg:schema, like Chromium.
		if bus.Call(ctx, owner, secretServicePath, secretServiceInterface+".SearchItems", attrs).Store(&unlocked, &locked) != nil {
			return nil, safeStorageCallError(ctx)
		}
		if len(locked) != 0 {
			return nil, errLinuxSafeStorageLocked
		}
		if len(unlocked) != 1 || unlocked[0] != item {
			return nil, errLinuxSafeStorageIncompatible
		}
	}
	if item == "/" || !item.IsValid() {
		return nil, errLinuxSafeStorageIncompatible
	}
	if err := safeStorageUnlocked(ctx, bus, owner, item, secretItemInterface); err != nil {
		return nil, err
	}
	var secret safeStorageSecret
	if bus.Call(ctx, owner, item, secretItemInterface+".GetSecret", session).Store(&secret) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if secret.Session != session || len(secret.Parameters) != 0 || (secret.ContentType != "text/plain" && secret.ContentType != "text/plain; charset=utf8" && secret.ContentType != "text/plain; charset=utf-8") || len(secret.Value) == 0 || bytes.IndexByte(secret.Value, 0) >= 0 {
		clear(secret.Value)
		return nil, errLinuxSafeStorageIncompatible
	}
	return secret.Value, nil
}

func randomSafeStoragePassword() ([]byte, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return nil, errors.New("generating Linux safeStorage password failed")
	}
	defer clear(raw[:])
	password := make([]byte, base64.StdEncoding.EncodedLen(len(raw)))
	base64.StdEncoding.Encode(password, raw[:])
	return password, nil
}

type linuxSafeStorageEncryptor struct {
	mu    sync.Mutex
	ctx   context.Context
	block cipher.Block
}

func newLinuxSafeStorageEncryptor(ctx context.Context, password []byte) (sessionValueEncryptor, error) {
	if len(password) == 0 {
		return nil, errLinuxSafeStorageIncompatible
	}
	key := pbkdf2.Key(password, []byte("saltysalt"), 1, 16, sha1.New)
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, errLinuxSafeStorageIncompatible
	}
	return &linuxSafeStorageEncryptor{ctx: ctx, block: block}, nil
}

func (e *linuxSafeStorageEncryptor) Encrypt(plaintext []byte) ([]byte, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.block == nil {
		return nil, errors.New("Linux safeStorage encryptor is closed")
	}
	if err := e.ctx.Err(); err != nil {
		return nil, err
	}
	if len(plaintext) == 0 {
		// OSCrypt::EncryptString returns an empty string before adding v11.
		return []byte{}, nil
	}
	padding := aes.BlockSize - len(plaintext)%aes.BlockSize
	result := make([]byte, 3+len(plaintext)+padding)
	copy(result, "v11")
	payload := result[3:]
	copy(payload, plaintext)
	for i := len(plaintext); i < len(payload); i++ {
		payload[i] = byte(padding)
	}
	var iv = [aes.BlockSize]byte{' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '}
	cipher.NewCBCEncrypter(e.block, iv[:]).CryptBlocks(payload, payload)
	return result, nil
}

// Close releases the expanded AES key reference. Go's AES implementation does
// not expose an expanded-key wipe; password and PBKDF2 byte buffers are cleared
// separately. The narrow importer interface remains Encrypt-only; callers may
// type-assert io.Closer for prompt release after a migration.
func (e *linuxSafeStorageEncryptor) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.block = nil
	return nil
}
