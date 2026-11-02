package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"debug/elf"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"

	"github.com/klauspost/compress/zstd"
	"github.com/ulikunitz/xz"
)

const hardwareMetadataLimit = 16 << 20

type hardwareNode struct {
	data  []byte
	link  string
	layer int
}

func hardwareBlobPath(layout, digest string) (string, error) {
	h, ok := strings.CutPrefix(digest, "sha256:")
	if !ok || len(h) != 64 {
		return "", fmt.Errorf("unsupported OCI digest %q", digest)
	}
	if _, err := hex.DecodeString(h); err != nil {
		return "", err
	}
	return filepath.Join(layout, "blobs", "sha256", h), nil
}

func hardwareManifest(layout string) (ociManifest, error) {
	var index, manifest ociManifest
	data, err := os.ReadFile(filepath.Join(layout, "index.json"))
	if err != nil {
		return manifest, err
	}
	if err = json.Unmarshal(data, &index); err != nil {
		return manifest, err
	}
	if len(index.Manifests) != 1 {
		return manifest, fmt.Errorf("expected one selected platform manifest")
	}
	name, err := hardwareBlobPath(layout, index.Manifests[0].Digest)
	if err != nil {
		return manifest, err
	}
	data, err = os.ReadFile(name)
	if err != nil {
		return manifest, err
	}
	if err = json.Unmarshal(data, &manifest); err != nil {
		return manifest, err
	}
	if len(manifest.Layers) == 0 {
		return manifest, fmt.Errorf("image has no layers")
	}
	return manifest, nil
}

// Streams verified local layers without extracting files or trusting tar paths.
func hardwareReadLayer(ctx context.Context, layout string, d ociDescriptor, visit func(*tar.Header, io.Reader) error) error {
	name, err := hardwareBlobPath(layout, d.Digest)
	if err != nil {
		return err
	}
	f, err := os.Open(name)
	if err != nil {
		return err
	}
	defer f.Close()
	var r io.Reader = f
	switch d.MediaType {
	case "application/vnd.oci.image.layer.v1.tar+gzip", "application/vnd.docker.image.rootfs.diff.tar.gzip", "application/vnd.oci.image.layer.nondistributable.v1.tar+gzip":
		g, err := gzip.NewReader(f)
		if err != nil {
			return err
		}
		defer g.Close()
		r = g
	case "application/vnd.oci.image.layer.v1.tar+zstd", "application/vnd.oci.image.layer.nondistributable.v1.tar+zstd":
		z, err := zstd.NewReader(f, zstd.WithDecoderMaxMemory(256<<20))
		if err != nil {
			return err
		}
		defer z.Close()
		r = z
	case "application/vnd.oci.image.layer.v1.tar", "application/vnd.oci.image.layer.nondistributable.v1.tar":
	default:
		return fmt.Errorf("unsupported layer media type %q", d.MediaType)
	}
	t := tar.NewReader(r)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		h, err := t.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		h.Name = path.Clean(strings.TrimPrefix(h.Name, "./"))
		if strings.HasPrefix(h.Name, "/") || h.Name == ".." || strings.HasPrefix(h.Name, "../") {
			return fmt.Errorf("unsafe layer path")
		}
		if err := visit(h, t); err != nil {
			return err
		}
	}
}

func hardwareRelevant(name string) bool {
	return name == "usr" || name == "usr/lib" || name == "lib" || strings.HasPrefix(name, "usr/lib/modules/") || strings.HasPrefix(name, "usr/lib/firmware/") || strings.HasPrefix(name, "lib/modules/") || strings.HasPrefix(name, "lib/firmware/")
}

func hardwareModuleFromPath(name string) string {
	base := path.Base(name)
	for _, ext := range []string{".ko.xz", ".ko.zst", ".ko.gz", ".ko"} {
		if stem, ok := strings.CutSuffix(base, ext); ok {
			return hardwareModuleName(stem)
		}
	}
	return ""
}

func hardwareRemove(nodes map[string]hardwareNode, name string) {
	for n := range nodes {
		if n == name || strings.HasPrefix(n, name+"/") {
			delete(nodes, n)
		}
	}
}

func hardwareResolveNode(nodes map[string]hardwareNode, name string) (hardwareNode, bool) {
	for range 40 {
		n, ok := nodes[name]
		if !ok {
			return hardwareNode{}, false
		}
		if n.link == "" {
			return n, true
		}
		name = n.link
	}
	return hardwareNode{}, false
}

func readHardwareInventory(ctx context.Context, layout string, devices []hardwareDevice) (hardwareKernel, error) {
	k := hardwareKernel{modules: map[string]string{}, builtin: map[string]bool{}, firmware: map[string]bool{}, moduleFirmware: map[string][]string{}, firmwareUnknown: map[string]bool{}}
	manifest, err := hardwareManifest(layout)
	if err != nil {
		return k, err
	}
	nodes := map[string]hardwareNode{}
	for layer, descriptor := range manifest.Layers {
		added, removed := map[string]hardwareNode{}, []string{}
		err := hardwareReadLayer(ctx, layout, descriptor, func(h *tar.Header, r io.Reader) error {
			base, dir := path.Base(h.Name), path.Dir(h.Name)
			if base == ".wh..wh..opq" {
				removed = append(removed, dir)
				return nil
			}
			if strings.HasPrefix(base, ".wh.") {
				removed = append(removed, path.Join(dir, strings.TrimPrefix(base, ".wh.")))
				return nil
			}
			if !hardwareRelevant(h.Name) {
				return nil
			}
			n := hardwareNode{layer: layer}
			switch h.Typeflag {
			case tar.TypeSymlink, tar.TypeLink:
				if h.Typeflag == tar.TypeLink || strings.HasPrefix(h.Linkname, "/") {
					n.link = path.Clean(strings.TrimPrefix(h.Linkname, "/"))
				} else {
					n.link = path.Join(dir, h.Linkname)
				}
			case tar.TypeReg, tar.TypeRegA:
				switch base {
				case "modules.dep", "modules.builtin", "modules.alias", "modules.builtin.alias", "modules.builtin.modinfo":
					if h.Size > hardwareMetadataLimit {
						return fmt.Errorf("kernel metadata too large")
					}
					data, err := io.ReadAll(io.LimitReader(r, hardwareMetadataLimit+1))
					if err != nil {
						return err
					}
					n.data = data
				}
			default:
				return nil
			}
			added[h.Name] = n
			return nil
		})
		if err != nil {
			if ctx.Err() != nil {
				return k, ctx.Err()
			}
			k.partial = true
			continue
		}
		// Whiteouts affect only lower layers, regardless of tar entry order.
		for _, name := range removed {
			hardwareRemove(nodes, name)
		}
		for name, node := range added {
			nodes[name] = node
		}
	}
	versions := map[string]bool{}
	for name := range nodes {
		for _, prefix := range []string{"usr/lib/modules/", "lib/modules/"} {
			if rel, ok := strings.CutPrefix(name, prefix); ok {
				if version, _, ok := strings.Cut(rel, "/"); ok {
					versions[prefix+version] = true
				}
			}
		}
	}
	if len(versions) == 0 {
		return k, fmt.Errorf("target kernel metadata not found")
	}
	roots := make([]string, 0, len(versions))
	for root := range versions {
		roots = append(roots, root)
	}
	sort.Strings(roots)
	root := roots[len(roots)-1]
	k.version = path.Base(root)
	if len(roots) != 1 {
		k.partial = true
	}
	get := func(base string) []byte {
		node, ok := hardwareResolveNode(nodes, root+"/"+base)
		if !ok {
			k.partial = true
		}
		return node.data
	}
	dep, builtin, aliases := get("modules.dep"), get("modules.builtin"), get("modules.alias")
	for _, line := range strings.Split(string(dep), "\n") {
		name, _, _ := strings.Cut(line, ":")
		name = path.Join(root, strings.TrimSpace(name))
		if m := hardwareModuleFromPath(name); m != "" {
			if _, ok := hardwareResolveNode(nodes, name); ok {
				k.modules[m] = name
			}
		}
	}
	for _, line := range strings.Split(string(builtin), "\n") {
		if m := hardwareModuleFromPath(strings.TrimSpace(line)); m != "" {
			k.builtin[m] = true
		}
	}
	builtinInfo, hasBuiltinInfo := hardwareResolveNode(nodes, root+"/modules.builtin.modinfo")
	if node, ok := hardwareResolveNode(nodes, root+"/modules.builtin.alias"); ok {
		aliases = append(append(append([]byte{}, aliases...), '\n'), node.data...)
	} else if len(k.builtin) > 0 && !hasBuiltinInfo {
		// depmod commonly writes only modules.builtin.alias.bin. The
		// original .modinfo records provide the same aliases without
		// requiring a distribution-specific binary depmod parser.
		k.partial = true
	}
	if hasBuiltinInfo {
		for _, field := range bytes.Split(builtinInfo.data, []byte{0}) {
			if name, value, ok := strings.Cut(string(field), ".alias="); ok {
				k.aliases = append(k.aliases, hardwareAlias{value, hardwareModuleName(name)})
			}
			if name, value, ok := strings.Cut(string(field), ".firmware="); ok {
				m := hardwareModuleName(name)
				k.moduleFirmware[m] = append(k.moduleFirmware[m], value)
			}
		}
	}
	for _, line := range strings.Split(string(aliases), "\n") {
		f := strings.Fields(line)
		if len(f) == 3 && f[0] == "alias" {
			k.aliases = append(k.aliases, hardwareAlias{f[1], hardwareModuleName(f[2])})
		}
	}
	if len(k.aliases) == 0 {
		k.partial = true
	}
	for name := range nodes {
		for _, prefix := range []string{"usr/lib/firmware/", "lib/firmware/"} {
			if rel, ok := strings.CutPrefix(name, prefix); ok {
				if _, exists := hardwareResolveNode(nodes, name); exists {
					k.firmware[hardwareFirmwareName(rel)] = true
				}
			}
		}
	}
	wanted := map[string]string{}
	for _, dev := range devices {
		if dev.Uncertain {
			continue
		}
		for _, m := range k.drivers(dev.Modalias) {
			if name := k.modules[m]; name != "" {
				wanted[name] = m
			} else if !hasBuiltinInfo {
				k.firmwareUnknown[m] = true
			}
		}
	}
	for layer, descriptor := range manifest.Layers {
		needed := false
		for name := range wanted {
			node, ok := hardwareResolveNode(nodes, name)
			if ok && node.layer == layer {
				needed = true
				break
			}
		}
		if !needed {
			continue
		}
		err := hardwareReadLayer(ctx, layout, descriptor, func(h *tar.Header, r io.Reader) error {
			m, ok := wanted[h.Name]
			if !ok {
				return nil
			}
			node, ok := hardwareResolveNode(nodes, h.Name)
			if !ok || node.layer != layer {
				return nil
			}
			fw, err := hardwareReadModuleFirmware(h.Name, r)
			if err != nil {
				k.firmwareUnknown[m] = true
			} else {
				k.moduleFirmware[m] = fw
			}
			delete(wanted, h.Name)
			return nil
		})
		if err != nil {
			if ctx.Err() != nil {
				return k, ctx.Err()
			}
			for _, m := range wanted {
				k.firmwareUnknown[m] = true
			}
		}
	}
	for _, m := range wanted {
		k.firmwareUnknown[m] = true
	}
	return k, nil
}

func hardwareReadModuleFirmware(name string, source io.Reader) ([]string, error) {
	var r io.Reader = source
	switch {
	case strings.HasSuffix(name, ".xz"):
		x, err := (xz.ReaderConfig{DictCap: 64 << 20}).NewReader(source)
		if err != nil {
			return nil, err
		}
		r = x
	case strings.HasSuffix(name, ".zst"):
		z, err := zstd.NewReader(source, zstd.WithDecoderMaxMemory(64<<20))
		if err != nil {
			return nil, err
		}
		defer z.Close()
		r = z
	case strings.HasSuffix(name, ".gz"):
		g, err := gzip.NewReader(source)
		if err != nil {
			return nil, err
		}
		defer g.Close()
		r = g
	}
	data, err := io.ReadAll(io.LimitReader(r, hardwareMetadataLimit+1))
	if err != nil {
		return nil, err
	}
	if len(data) > hardwareMetadataLimit {
		return nil, fmt.Errorf("module metadata too large")
	}
	file, err := elf.NewFile(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer file.Close()
	section := file.Section(".modinfo")
	if section == nil {
		return nil, fmt.Errorf("module has no modinfo")
	}
	if section.Size > hardwareMetadataLimit {
		return nil, fmt.Errorf("modinfo too large")
	}
	data, err = section.Data()
	if err != nil {
		return nil, err
	}
	firmware := []string{}
	for _, field := range bytes.Split(data, []byte{0}) {
		if value, ok := strings.CutPrefix(string(field), "firmware="); ok {
			firmware = append(firmware, hardwareFirmwareName(value))
		}
	}
	return firmware, nil
}
