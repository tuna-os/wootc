//go:build linux

package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"io"
	"reflect"
	"testing"

	"github.com/godbus/dbus/v5"
)

func kWalletTestStep(backend string, method string, args, reply []any) safeStorageTestStep {
	path := dbus.ObjectPath("/modules/kwalletd5")
	if backend == "kwallet6" {
		path = "/modules/kwalletd6"
	}
	return safeStorageTestStep{path: path, method: kWalletInterface + "." + method, args: args, reply: reply}
}

func kWalletInitialTestSteps(backend string) []safeStorageTestStep {
	service := "org.kde.kwalletd5"
	if backend == "kwallet6" {
		service = "org.kde.kwalletd6"
	}
	return []safeStorageTestStep{
		safeStorageOwnerStep(service),
		kWalletTestStep(backend, "isEnabled", nil, []any{true}),
		kWalletTestStep(backend, "networkWallet", nil, []any{"kdewallet"}),
		kWalletTestStep(backend, "wallets", nil, []any{[]string{"kdewallet"}}),
	}
}

func kWalletHandleTestSteps(backend string) []safeStorageTestStep {
	return []safeStorageTestStep{
		kWalletTestStep(backend, "isOpen", []any{"kdewallet"}, []any{true}),
		kWalletTestStep(backend, "open", []any{"kdewallet", int64(0), "Google Chrome"}, []any{int32(7)}),
		kWalletTestStep(backend, "isOpen", []any{int32(7)}, []any{true}),
	}
}

func kWalletCloseTestStep(backend string) safeStorageTestStep {
	return kWalletTestStep(backend, "close", []any{int32(7), false, "Google Chrome"}, []any{int32(0)})
}

func TestKWalletSafeStorageRetrieval(t *testing.T) {
	for _, backend := range []string{"kwallet5", "kwallet6"} {
		t.Run(backend, func(t *testing.T) {
			steps := kWalletInitialTestSteps(backend)
			steps = append(steps, kWalletHandleTestSteps(backend)...)
			steps = append(steps,
				kWalletTestStep(backend, "hasFolder", []any{int32(7), "Chrome Keys", "Google Chrome"}, []any{true}),
				kWalletTestStep(backend, "hasEntry", []any{int32(7), "Chrome Keys", "Chrome Safe Storage", "Google Chrome"}, []any{true}),
				kWalletTestStep(backend, "entryType", []any{int32(7), "Chrome Keys", "Chrome Safe Storage", "Google Chrome"}, []any{int32(1)}),
				kWalletTestStep(backend, "readPassword", []any{int32(7), "Chrome Keys", "Chrome Safe Storage", "Google Chrome"}, []any{safeStorageFixturePassword}),
				kWalletCloseTestStep(backend),
			)
			bus := newSafeStorageTestBus(t, steps)
			identity, _ := linuxSafeStorageIdentityFor("chrome")
			encryptor, err := openLinuxSafeStorageOnBus(bus.ctx, bus, backend, identity)
			if err != nil {
				t.Fatal(err)
			}
			defer encryptor.(io.Closer).Close()
			assertLinuxSafeStorageFixtures(t, encryptor)
		})
	}
}

func TestKWalletSafeStorageCreation(t *testing.T) {
	for _, backend := range []string{"kwallet5", "kwallet6"} {
		t.Run(backend, func(t *testing.T) {
			var stored string
			write := kWalletTestStep(backend, "writePassword", nil, nil)
			write.hook = func(args []any) []any {
				if dbus.SignatureOf(args...).String() != "issss" {
					t.Fatal("writePassword wire signature differs")
				}
				if !reflect.DeepEqual(args[:3], []any{int32(7), "Chrome Keys", "Chrome Safe Storage"}) || args[4] != "Google Chrome" {
					t.Fatal("incorrect Chromium wallet identity")
				}
				stored = args[3].(string)
				raw, err := base64.StdEncoding.DecodeString(stored)
				if err != nil || len(raw) != 16 {
					t.Fatal("new password is not Chromium's base64-encoded 16 random bytes")
				}
				return []any{int32(0)}
			}
			read := kWalletTestStep(backend, "readPassword", nil, nil)
			read.hook = func(args []any) []any {
				if !reflect.DeepEqual(args, []any{int32(7), "Chrome Keys", "Chrome Safe Storage", "Google Chrome"}) {
					t.Fatal("incorrect readPassword arguments")
				}
				return []any{stored}
			}
			steps := kWalletInitialTestSteps(backend)
			steps = append(steps, kWalletHandleTestSteps(backend)...)
			steps = append(steps,
				kWalletTestStep(backend, "hasFolder", []any{int32(7), "Chrome Keys", "Google Chrome"}, []any{false}),
				kWalletTestStep(backend, "createFolder", []any{int32(7), "Chrome Keys", "Google Chrome"}, []any{true}),
				kWalletTestStep(backend, "hasEntry", []any{int32(7), "Chrome Keys", "Chrome Safe Storage", "Google Chrome"}, []any{false}), write,
				kWalletTestStep(backend, "entryType", []any{int32(7), "Chrome Keys", "Chrome Safe Storage", "Google Chrome"}, []any{int32(1)}), read,
				kWalletCloseTestStep(backend),
			)
			bus := newSafeStorageTestBus(t, steps)
			identity, _ := linuxSafeStorageIdentityFor("chrome")
			encryptor, err := openLinuxSafeStorageOnBus(bus.ctx, bus, backend, identity)
			if err != nil {
				t.Fatal(err)
			}
			defer encryptor.(io.Closer).Close()
			expected, err := newLinuxSafeStorageEncryptor(bus.ctx, []byte(stored))
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
		})
	}
}

func TestKWalletSafeStorageFailClosed(t *testing.T) {
	for _, backend := range []string{"kwallet5", "kwallet6"} {
		t.Run(backend, func(t *testing.T) {
			for _, tc := range []struct {
				name  string
				steps []safeStorageTestStep
				want  error
			}{
				{"disabled", []safeStorageTestStep{safeStorageOwnerStep("org.kde.kwalletd" + backend[len(backend)-1:]), kWalletTestStep(backend, "isEnabled", nil, []any{false})}, errLinuxSafeStorageUnavailable},
				{"missing", append(kWalletInitialTestSteps(backend)[:3], kWalletTestStep(backend, "wallets", nil, []any{[]string{}})), errLinuxSafeStorageMissing},
				{"locked", append(kWalletInitialTestSteps(backend), kWalletTestStep(backend, "isOpen", []any{"kdewallet"}, []any{false})), errLinuxSafeStorageLocked},
				{"denied", append(append(kWalletInitialTestSteps(backend), kWalletTestStep(backend, "isOpen", []any{"kdewallet"}, []any{true})), kWalletTestStep(backend, "open", []any{"kdewallet", int64(0), "Google Chrome"}, []any{int32(-1)})), errLinuxSafeStorageUnavailable},
			} {
				t.Run(tc.name, func(t *testing.T) {
					bus := newSafeStorageTestBus(t, tc.steps)
					identity, _ := linuxSafeStorageIdentityFor("chrome")
					if _, err := openLinuxSafeStorageOnBus(bus.ctx, bus, backend, identity); !errors.Is(err, tc.want) {
						t.Fatalf("wrong fail-closed error: %v", err)
					}
				})
			}
		})
	}
}

func TestKWalletSafeStorageNeverReplacesIncompatibleEntry(t *testing.T) {
	for _, backend := range []string{"kwallet5", "kwallet6"} {
		t.Run(backend, func(t *testing.T) {
			steps := kWalletInitialTestSteps(backend)
			steps = append(steps, kWalletHandleTestSteps(backend)...)
			steps = append(steps,
				kWalletTestStep(backend, "hasFolder", []any{int32(7), "Chrome Keys", "Google Chrome"}, []any{true}),
				kWalletTestStep(backend, "hasEntry", []any{int32(7), "Chrome Keys", "Chrome Safe Storage", "Google Chrome"}, []any{true}),
				kWalletTestStep(backend, "entryType", []any{int32(7), "Chrome Keys", "Chrome Safe Storage", "Google Chrome"}, []any{int32(2)}),
				kWalletCloseTestStep(backend),
			)
			bus := newSafeStorageTestBus(t, steps)
			identity, _ := linuxSafeStorageIdentityFor("chrome")
			if _, err := openLinuxSafeStorageOnBus(bus.ctx, bus, backend, identity); !errors.Is(err, errLinuxSafeStorageIncompatible) {
				t.Fatalf("incompatible entry accepted: %v", err)
			}
		})
	}
}
