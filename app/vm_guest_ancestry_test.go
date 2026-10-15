package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestVMGuestIndependentAncestryConsumer(t *testing.T) {
	req, reply := guestProbeFixture()
	raw, _ := json.Marshal(reply)
	if _, e := decodeVMGuestObservation(raw, req); e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct{ name, key, value string }{
		{"wrong-gpt", "BLOCKS", `{"blockdevices":[{"name":"/dev/vdb","kname":"/dev/vdb","type":"disk","maj:min":"8:16","ptuuid":"foreign","children":[{"name":"/dev/vdb3","kname":"/dev/vdb3","type":"part","maj:min":"8:19"}]}]}`},
		{"missing-parent", "BLOCKS", `{"blockdevices":[{"name":"/dev/vdb","kname":"/dev/vdb","type":"disk","maj:min":"8:16","ptuuid":"12345678-1234-1234-1234-123456789abc"},{"name":"/dev/vdb3","kname":"/dev/vdb3","type":"part","maj:min":"8:19"}]}`},
		{"wrong-current-root", "MOUNTS", `{"filesystems":[{"target":"/","source":"/dev/vda3","maj:min":"8:3","fstype":"ext4","options":"rw"}]}`},
		{"source-major-disagree", "MOUNTS", `{"filesystems":[{"target":"/","source":"/dev/vdb3","maj:min":"8:20","fstype":"ext4","options":"rw"}]}`},
		{"workdir-only", "MOUNTS", `{"filesystems":[{"target":"/","source":"overlay","maj:min":"0:55","fstype":"overlay","options":"rw,workdir=/var/work"}]}`},
		{"unresolved-lower", "MOUNTS", `{"filesystems":[{"target":"/","source":"overlay","maj:min":"0:55","fstype":"overlay","options":"rw,lowerdir=/lower"}]}`},
		{"btrfs-unobserved-members", "MOUNTS", `{"filesystems":[{"target":"/","source":"/dev/vdb3[/root]","maj:min":"0:55","uuid":"12345678-1234-1234-1234-123456789abc","fstype":"btrfs","options":"rw"}]}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, r := guestProbeFixture()
			m := r["root"].(map[string]any)["measurements"].(map[string]string)
			m[tc.key] = base64.StdEncoding.EncodeToString([]byte(tc.value))
			b, _ := json.Marshal(r)
			if _, e := decodeVMGuestObservation(b, req); e == nil {
				t.Fatal("guest asserted currentRootVerified accepted without measured selected ancestry")
			}
		})
	}
	// An actual positive dm chain must follow every measured parent.
	_, r := guestProbeFixture()
	m := r["root"].(map[string]any)["measurements"].(map[string]string)
	b, _ := base64.StdEncoding.DecodeString(m["BLOCKS"])
	var graph map[string]any
	json.Unmarshal(b, &graph)
	disk := graph["blockdevices"].([]any)[0].(map[string]any)
	part := disk["children"].([]any)[0].(map[string]any)
	part["children"] = []any{map[string]any{"name": "/dev/mapper/root", "kname": "/dev/dm-0", "type": "crypt", "maj:min": "253:0"}}
	b, _ = json.Marshal(graph)
	m["BLOCKS"] = base64.StdEncoding.EncodeToString(b)
	m["MOUNTS"] = base64.StdEncoding.EncodeToString([]byte(`{"filesystems":[{"target":"/","source":"/dev/mapper/root","maj:min":"253:0","fstype":"ext4","options":"rw"}]}`))
	raw, _ = json.Marshal(r)
	if _, e := decodeVMGuestObservation(raw, req); e != nil {
		t.Fatal(e)
	}
	// The loop type is an observed edge, not a substring ban on source text.
	encoded := m["BLOCKS"]
	b, _ = base64.StdEncoding.DecodeString(encoded)
	m["BLOCKS"] = base64.StdEncoding.EncodeToString([]byte(strings.Replace(string(b), `"type":"crypt"`, `"type":"loop"`, 1)))
	raw, _ = json.Marshal(r)
	if _, e := decodeVMGuestObservation(raw, req); e == nil {
		t.Fatal("loop-backed current root accepted")
	}
}

func TestVMGuestMeasuredProjectionAndMembers(t *testing.T) {
	req, _ := guestProbeFixture()
	rootFor := func(blocks, mounts, loops, paths, members string) vmGuestProbeRoot {
		m := map[string]string{}
		for k, v := range map[string]string{"BLOCKS": blocks, "MOUNTS": mounts, "LOOPS": loops, "PATHS": paths, "BTRFS": members} {
			m[k] = base64.StdEncoding.EncodeToString([]byte(v))
		}
		return vmGuestProbeRoot{Target: "/dev/vdb", DiskID: req.DiskID, CurrentRootVerified: true, Measurements: m}
	}
	blocks := `{"blockdevices":[{"name":"/dev/vdb","kname":"/dev/vdb","type":"disk","maj:min":"8:16","ptuuid":"12345678-1234-1234-1234-123456789abc","children":[{"name":"/dev/vdb3","kname":"/dev/vdb3","type":"part","maj:min":"8:19"}]},{"name":"/dev/loop0","kname":"/dev/loop0","type":"loop","maj:min":"7:0"}]}`
	mounts := `{"filesystems":[{"target":"/","source":"overlay","maj:min":"0:55","fstype":"overlay","options":"rw,lowerdir=/lower,upperdir=/var/upper,workdir=/var/work"},{"target":"/lower","source":"/dev/loop0","maj:min":"7:0","fstype":"erofs","options":"ro"},{"target":"/var","source":"/dev/vdb3","maj:min":"8:19","fstype":"ext4","options":"rw"}]}`
	loops := `{"loopdevices":[{"name":"/dev/loop0","maj:min":"7:0","back-file":"/var/image"}]}`
	paths := "/lower\t/lower\n/var/upper\t/var/upper\n/var/work\t/var/work\n/var/image\t/var/image"
	root := rootFor(blocks, mounts, loops, paths, "")
	if e := verifyVMGuestRoot(root, req.DiskID); e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct{ name, key, old, new string }{
		{"symlink-foreign", "PATHS", "/var/image\t/var/image", "/var/image\t/foreign/image"},
		{"unresolved", "PATHS", "/lower\t/lower", "/lower\t-"},
		{"duplicate-layer", "MOUNTS", "lowerdir=/lower", "lowerdir=/lower,lowerdir=/lower"},
		{"missing-upper", "MOUNTS", ",upperdir=/var/upper", ""},
		{"deleted-loopfile", "LOOPS", "/var/image", "/var/image (deleted)"},
		{"loop-alias-mismatch", "LOOPS", "7:0", "7:1"},
		{"projection-self", "PATHS", "/var/image\t/var/image", "/var/image\t/rootimage"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := rootFor(blocks, mounts, loops, paths, "")
			b, _ := base64.StdEncoding.DecodeString(r.Measurements[tc.key])
			r.Measurements[tc.key] = base64.StdEncoding.EncodeToString([]byte(strings.Replace(string(b), tc.old, tc.new, 1)))
			if e := verifyVMGuestRoot(r, req.DiskID); e == nil {
				t.Fatal("invalid projection accepted")
			}
		})
	}
	fsid := "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	btrfsBlocks := strings.Replace(blocks, `"type":"part","maj:min":"8:19"`, `"type":"part","maj:min":"8:19","uuid":"`+fsid+`"`, 1)
	btrfsMounts := `{"filesystems":[{"target":"/","source":"/dev/vdb3[/root]","maj:min":"0:55","uuid":"` + fsid + `","fstype":"btrfs","options":"rw"}]}`
	r := rootFor(btrfsBlocks, btrfsMounts, `{"loopdevices":[]}`, "", fsid+"\t1\t8:19")
	if e := verifyVMGuestRoot(r, req.DiskID); e != nil {
		t.Fatal(e)
	}
	// Membership on the selected disk still requires every measured member UUID.
	var bg map[string]any
	json.Unmarshal([]byte(btrfsBlocks), &bg)
	bd := bg["blockdevices"].([]any)[0].(map[string]any)
	bd["children"] = append(bd["children"].([]any), map[string]any{"name": "/dev/vdb4", "kname": "/dev/vdb4", "type": "part", "maj:min": "8:20", "uuid": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"})
	bb, _ := json.Marshal(bg)
	contradictory := rootFor(string(bb), btrfsMounts, `{"loopdevices":[]}`, "", fsid+"\t1\t8:19,8:20")
	if e := verifyVMGuestRoot(contradictory, req.DiskID); e == nil {
		t.Fatal("contradictory measured Btrfs member UUID accepted")
	}
	for _, members := range []string{fsid + "\t0\t8:19", fsid + "\t1\t8:19,8:19", fsid + "\t1\t8:19,8:3", fsid + "\t1\t8:3"} {
		r := rootFor(btrfsBlocks, btrfsMounts, `{"loopdevices":[]}`, "", members)
		if e := verifyVMGuestRoot(r, req.DiskID); e == nil {
			t.Fatal("unverified Btrfs membership accepted")
		}
	}
}
