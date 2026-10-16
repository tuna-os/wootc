//go:build windows

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"testing"
)

// The install session over the real one-shot authority from #606, bound to
// this process's actual captured token. The action only records: no test here
// can start an install or write to a disk.
func TestNativeInstallSessionActualOneShotAuthority(t *testing.T) {
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
	const session, brand = "0123456789abcdef0123456789abcdef", "wootc"
	observations := 0
	newServer := func(revalidate func() error, starts *[]InstallConfig) *Server {
		prepare := func(plan InstallConfig) (nativeInstallAuthority, NativeInstallGrant, error) {
			authority, err := prepareNativeInstallAuthorization(user, session, brand, plan, func(InstallConfig) error { return nil }, func() error { observations++; return revalidate() })
			if err != nil {
				return nil, NativeInstallGrant{}, err
			}
			return authority, NativeInstallGrant{SchemaVersion: 1, Session: session, BrandID: brand, IntentID: authority.intent, ImageRef: plan.ImageRef, StorageDrive: plan.StorageDrive, DiskSizeGB: plan.DiskSizeGB}, nil
		}
		return nativeInstallTestServer(t, prepare, func(config InstallConfig) error { *starts = append(*starts, config); return nil })
	}
	confirmation := func(intent string) json.RawMessage {
		data, _ := json.Marshal(nativeInstallConfirmation{Kind: "confirm-install", ProtocolVersion: 1, Session: session, BrandID: brand, IntentID: intent})
		return data
	}
	grantOf := func(t *testing.T, server *Server) NativeInstallGrant {
		t.Helper()
		result, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "PrepareNativeInstall", Params: json.RawMessage(nativeInstallPlanFixture)})
		grant, ok := result.(NativeInstallGrant)
		if failure != nil || !ok || !lowerHexLength(grant.IntentID, 32) {
			t.Fatalf("actual authority did not grant: %+v %+v", result, failure)
		}
		return grant
	}
	t.Run("granted-intent-starts-the-prepared-plan-once", func(t *testing.T) {
		var starts []InstallConfig
		server := newServer(func() error { return nil }, &starts)
		grant := grantOf(t, server)
		if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: confirmation(grant.IntentID)}); failure != nil {
			t.Fatal(failure)
		}
		if len(starts) != 1 || starts[0].Password != "public synthetic password" || starts[0].StorageDrive != "D" {
			t.Fatalf("prepared plan did not start once: %+v", starts)
		}
		if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: confirmation(grant.IntentID)}); failure == nil || len(starts) != 1 {
			t.Fatal("a consumed intent started again")
		}
	})
	for name, mutate := range map[string]func(NativeInstallGrant) json.RawMessage{
		"wrong-intent": func(NativeInstallGrant) json.RawMessage { return confirmation("ffffffffffffffffffffffffffffffff") },
		"replaced-plan": func(g NativeInstallGrant) json.RawMessage {
			return json.RawMessage(`{"imageRef":"ghcr.io/example/other:latest"}`)
		},
		"assessment": func(g NativeInstallGrant) json.RawMessage {
			c := confirmation(g.IntentID)
			return json.RawMessage(string(c)[:9] + "assessment" + string(c)[24:])
		},
		"empty": func(NativeInstallGrant) json.RawMessage { return nil },
	} {
		t.Run(name, func(t *testing.T) {
			var starts []InstallConfig
			server := newServer(func() error { return nil }, &starts)
			grant := grantOf(t, server)
			if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: mutate(grant)}); failure == nil {
				t.Fatal("an invalid confirmation was accepted")
			}
			if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: confirmation(grant.IntentID)}); failure == nil || len(starts) != 0 {
				t.Fatal("an invalid first confirmation left a reusable intent")
			}
		})
	}
	t.Run("changed-observation-refuses", func(t *testing.T) {
		var starts []InstallConfig
		changed := false
		server := newServer(func() error {
			if changed {
				return errors.New("public synthetic volume swap")
			}
			return nil
		}, &starts)
		grant := grantOf(t, server)
		changed = true
		if _, failure := server.dispatch(context.Background(), jsonrpcRequest{Method: "ConfirmNativeInstall", Params: confirmation(grant.IntentID)}); failure == nil || len(starts) != 0 {
			t.Fatal("a changed observation started an install")
		}
	})
	if observations == 0 {
		t.Fatal("the authority never revalidated its observation")
	}
}

func TestNativeInstallSessionLaunchRefusesUnknownPurpose(t *testing.T) {
	for _, purpose := range []string{"assessment", "Install", "install ", "repair"} {
		if code := runNativeServe([]string{"wootc-engine.exe", "--native-serve", "--session", "0123456789abcdef0123456789abcdef", "--source-pid", "4", "--purpose", purpose}); code != 1 {
			t.Fatalf("purpose %q was accepted", purpose)
		}
	}
}
