//go:build linux

package main

import (
	"context"
	"strings"

	"github.com/godbus/dbus/v5"
)

const kWalletInterface = "org.kde.KWallet"

func readKWalletPassword(ctx context.Context, bus safeStorageBus, backend string, identity linuxSafeStorageIdentity) ([]byte, error) {
	var service string
	var path dbus.ObjectPath
	switch backend {
	case "kwallet5":
		service, path = "org.kde.kwalletd5", "/modules/kwalletd5"
	case "kwallet6":
		service, path = "org.kde.kwalletd6", "/modules/kwalletd6"
	default:
		return nil, errLinuxSafeStorageIncompatible
	}
	owner, err := safeStorageOwner(ctx, bus, service)
	if err != nil {
		return nil, err
	}
	call := func(method string, args ...any) *dbus.Call {
		return bus.Call(ctx, owner, path, kWalletInterface+"."+method, args...)
	}
	var enabled bool
	if call("isEnabled").Store(&enabled) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if !enabled {
		return nil, errLinuxSafeStorageUnavailable
	}
	var wallet string
	if call("networkWallet").Store(&wallet) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if wallet == "" {
		return nil, errLinuxSafeStorageMissing
	}
	var wallets []string
	if call("wallets").Store(&wallets) != nil {
		return nil, safeStorageCallError(ctx)
	}
	found := false
	for _, name := range wallets {
		if name == wallet {
			found = true
			break
		}
	}
	if !found {
		return nil, errLinuxSafeStorageMissing
	}
	var opened bool
	if call("isOpen", wallet).Store(&opened) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if !opened {
		// Do not call open() for locked wallets, start kwalletd, or fall back
		// to a different wallet/backend. Unlocking belongs to the desktop.
		return nil, errLinuxSafeStorageLocked
	}
	// KWallet has no open-if-unlocked API. open() is required to obtain an
	// authorized handle even for an already-open wallet. A desktop lock
	// between isOpen and open can still trigger a daemon unlock request;
	// callers requiring an atomic noninteractive guarantee cannot use this
	// native API. See the documented KWallet prerequisite.
	var handle int32
	if call("open", wallet, int64(0), identity.walletApplication).Store(&handle) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if handle < 0 {
		return nil, errLinuxSafeStorageUnavailable
	}
	// Release only this application's handle, never force-close the wallet.
	defer call("close", handle, false, identity.walletApplication)
	if call("isOpen", handle).Store(&opened) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if !opened {
		return nil, errLinuxSafeStorageLocked
	}
	var hasFolder bool
	if call("hasFolder", handle, identity.folder, identity.walletApplication).Store(&hasFolder) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if !hasFolder {
		var created bool
		if call("createFolder", handle, identity.folder, identity.walletApplication).Store(&created) != nil {
			return nil, safeStorageCallError(ctx)
		}
		if !created {
			return nil, errLinuxSafeStorageUnavailable
		}
	}
	var hasEntry bool
	if call("hasEntry", handle, identity.folder, identity.label, identity.walletApplication).Store(&hasEntry) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if !hasEntry {
		password, err := randomSafeStoragePassword()
		if err != nil {
			return nil, err
		}
		defer clear(password)
		var result int32
		if call("writePassword", handle, identity.folder, identity.label, string(password), identity.walletApplication).Store(&result) != nil {
			return nil, safeStorageCallError(ctx)
		}
		if result != 0 {
			return nil, errLinuxSafeStorageUnavailable
		}
	}
	var entryType int32
	if call("entryType", handle, identity.folder, identity.label, identity.walletApplication).Store(&entryType) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if entryType != 1 { // KWallet::Wallet::Password, never delete/replace another type.
		return nil, errLinuxSafeStorageIncompatible
	}
	var password string
	if call("readPassword", handle, identity.folder, identity.label, identity.walletApplication).Store(&password) != nil {
		return nil, safeStorageCallError(ctx)
	}
	if password == "" || strings.IndexByte(password, 0) >= 0 {
		return nil, errLinuxSafeStorageIncompatible
	}
	// D-Bus's KWallet API requires strings; unlike this returned byte slice,
	// the decoder's immutable string storage cannot be explicitly wiped.
	return []byte(password), nil
}
