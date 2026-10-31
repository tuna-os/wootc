package main

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
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
)

const maxKernelInventoryFile = 64 << 20

type targetOverlay struct {
	moduleFiles map[string][]byte
	firmware    map[string]struct{}
}

type whiteout struct {
	path   string
	opaque bool
}

type layerInventory struct {
	whiteouts   []whiteout
	moduleFiles map[string][]byte
	firmware    map[string]struct{}
	hardlinks   map[string]string
}

// inspectOCIBundle reads only kernel metadata and firmware names from a local,
// digest-addressed OCI layout. A broken layer makes the inventory partial; it
// never turns an unreadable absence into a blocking compatibility result.
func inspectOCIBundle(ociDir string) (*TargetKernel, error) {
	indexRaw, err := readFileLimit(filepath.Join(ociDir, "index.json"), 32<<20)
	if err != nil {
		return nil, fmt.Errorf("read OCI index: %w", err)
	}
	var index ociManifest
	if err := json.Unmarshal(indexRaw, &index); err != nil || len(index.Manifests) == 0 {
		if err == nil {
			err = fmt.Errorf("index contains no manifest")
		}
		return nil, fmt.Errorf("parse OCI index: %w", err)
	}
	manifestPath, err := ociBlobPath(ociDir, index.Manifests[0].Digest)
	if err != nil {
		return nil, err
	}
	manifestRaw, err := readFileLimit(manifestPath, 32<<20)
	if err != nil {
		return nil, fmt.Errorf("read OCI manifest: %w", err)
	}
	var manifest ociManifest
	if err := json.Unmarshal(manifestRaw, &manifest); err != nil {
		return nil, fmt.Errorf("parse OCI manifest: %w", err)
	}

	overlay := targetOverlay{moduleFiles: make(map[string][]byte), firmware: make(map[string]struct{})}
	skipped := 0
	for _, descriptor := range manifest.Layers {
		blob, pathErr := ociBlobPath(ociDir, descriptor.Digest)
		if pathErr != nil {
			skipped++
			continue
		}
		if descriptor.Size >= 0 {
			if stat, statErr := os.Stat(blob); statErr != nil || stat.Size() != descriptor.Size {
				skipped++
				continue
			}
		}
		layer, scanErr := scanHardwareLayer(blob)
		if scanErr != nil {
			skipped++
			continue
		}
		applyHardwareLayer(&overlay, layer)
	}

	kernel := targetKernelFromOverlay(overlay)
	if kernel == nil {
		return nil, fmt.Errorf("the target image contains no readable kernel module inventory (%d layer(s) skipped)", skipped)
	}
	kernel.LayersSkipped = skipped
	return kernel, nil
}

func ociBlobPath(ociDir, digest string) (string, error) {
	hexPart, ok := strings.CutPrefix(digest, "sha256:")
	if !ok || len(hexPart) != 64 {
		return "", fmt.Errorf("unsupported OCI digest %q", digest)
	}
	if _, err := hex.DecodeString(hexPart); err != nil {
		return "", fmt.Errorf("invalid OCI digest %q", digest)
	}
	return filepath.Join(ociDir, "blobs", "sha256", hexPart), nil
}

func readFileLimit(name string, limit int64) ([]byte, error) {
	file, err := os.Open(name)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%s exceeds %d bytes", name, limit)
	}
	return data, nil
}

func scanHardwareLayer(blob string) (layerInventory, error) {
	layer := layerInventory{
		moduleFiles: make(map[string][]byte),
		firmware:    make(map[string]struct{}),
		hardlinks:   make(map[string]string),
	}
	if err := walkLayerTar(blob, func(header *tar.Header, reader io.Reader) error {
		name, ok := cleanArchivePath(header.Name)
		if !ok {
			return nil
		}
		if target, opaque, ok := whiteoutTarget(name); ok {
			layer.whiteouts = append(layer.whiteouts, whiteout{path: target, opaque: opaque})
			return nil
		}
		if strings.HasPrefix(name, "usr/lib/firmware/") && header.Typeflag != tar.TypeDir {
			layer.firmware[normalizeFirmware(strings.TrimPrefix(name, "usr/lib/firmware/"))] = struct{}{}
		}
		if !isKernelInventoryPath(name) {
			return nil
		}
		switch header.Typeflag {
		case tar.TypeReg, tar.TypeRegA:
			data, err := io.ReadAll(io.LimitReader(reader, maxKernelInventoryFile+1))
			if err != nil {
				return err
			}
			if len(data) > maxKernelInventoryFile {
				return fmt.Errorf("kernel inventory file %s exceeds %d bytes", name, maxKernelInventoryFile)
			}
			layer.moduleFiles[name] = data
		case tar.TypeLink:
			target, targetOK := cleanArchivePath(header.Linkname)
			if !targetOK {
				return fmt.Errorf("kernel inventory hard link %s has unsafe target %q", name, header.Linkname)
			}
			layer.hardlinks[name] = target
		}
		return nil
	}); err != nil {
		return layerInventory{}, err
	}
	if len(layer.hardlinks) == 0 {
		return layer, nil
	}

	wanted := make(map[string]struct{}, len(layer.hardlinks))
	for _, target := range layer.hardlinks {
		wanted[target] = struct{}{}
	}
	resolved := make(map[string][]byte, len(wanted))
	if err := walkLayerTar(blob, func(header *tar.Header, reader io.Reader) error {
		name, ok := cleanArchivePath(header.Name)
		if !ok {
			return nil
		}
		if _, needed := wanted[name]; !needed || (header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA) {
			return nil
		}
		data, err := io.ReadAll(io.LimitReader(reader, maxKernelInventoryFile+1))
		if err != nil {
			return err
		}
		if len(data) > maxKernelInventoryFile {
			return fmt.Errorf("kernel inventory hard-link target %s exceeds %d bytes", name, maxKernelInventoryFile)
		}
		resolved[name] = data
		return nil
	}); err != nil {
		return layerInventory{}, err
	}
	for name, target := range layer.hardlinks {
		data, ok := resolved[target]
		if !ok {
			return layerInventory{}, fmt.Errorf("kernel inventory hard link %s target %s is absent", name, target)
		}
		layer.moduleFiles[name] = data
	}
	return layer, nil
}

func walkLayerTar(blob string, visit func(*tar.Header, io.Reader) error) error {
	file, err := os.Open(blob)
	if err != nil {
		return err
	}
	defer file.Close()
	buffered := bufio.NewReader(file)
	magic, _ := buffered.Peek(4)
	var stream io.Reader = buffered
	var closeStream func()
	switch {
	case len(magic) >= 2 && magic[0] == 0x1f && magic[1] == 0x8b:
		gzipReader, gzipErr := gzip.NewReader(buffered)
		if gzipErr != nil {
			return gzipErr
		}
		stream = gzipReader
		closeStream = func() { _ = gzipReader.Close() }
	case len(magic) == 4 && magic[0] == 0x28 && magic[1] == 0xb5 && magic[2] == 0x2f && magic[3] == 0xfd:
		zstdReader, zstdErr := zstd.NewReader(buffered, zstd.WithDecoderConcurrency(1))
		if zstdErr != nil {
			return zstdErr
		}
		stream = zstdReader
		closeStream = zstdReader.Close
	}
	if closeStream != nil {
		defer closeStream()
	}
	tarReader := tar.NewReader(stream)
	for {
		header, nextErr := tarReader.Next()
		if nextErr == io.EOF {
			return nil
		}
		if nextErr != nil {
			return nextErr
		}
		if err := visit(header, tarReader); err != nil {
			return err
		}
	}
}

func cleanArchivePath(name string) (string, bool) {
	name = strings.TrimPrefix(strings.ReplaceAll(name, "\\", "/"), "./")
	if name == "" || strings.HasPrefix(name, "/") {
		return "", false
	}
	clean := path.Clean(name)
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", false
	}
	return clean, true
}

func whiteoutTarget(name string) (target string, opaque bool, ok bool) {
	dir, base := path.Split(name)
	dir = strings.TrimSuffix(dir, "/")
	if base == ".wh..wh..opq" {
		return dir, true, true
	}
	removed, found := strings.CutPrefix(base, ".wh.")
	if !found || removed == "" {
		return "", false, false
	}
	if dir == "" {
		return removed, false, true
	}
	return dir + "/" + removed, false, true
}

func isKernelInventoryPath(name string) bool {
	rest, ok := strings.CutPrefix(name, "usr/lib/modules/")
	if !ok {
		return false
	}
	kversion, file, ok := strings.Cut(rest, "/")
	if !ok || kversion == "" || strings.Contains(file, "/") {
		return false
	}
	switch file {
	case "modules.dep", "modules.builtin", "modules.alias", "modules.builtin.alias", "modules.builtin.modinfo":
		return true
	default:
		return false
	}
}

func applyHardwareLayer(overlay *targetOverlay, layer layerInventory) {
	for _, removal := range layer.whiteouts {
		prefix := removal.path + "/"
		for name := range overlay.moduleFiles {
			if name == removal.path || strings.HasPrefix(name, prefix) {
				delete(overlay.moduleFiles, name)
			}
		}
		if removal.path == "usr/lib/firmware" {
			clear(overlay.firmware)
		} else if relative, ok := strings.CutPrefix(removal.path, "usr/lib/firmware/"); ok {
			relative = normalizeFirmware(relative)
			firmwarePrefix := relative + "/"
			for name := range overlay.firmware {
				if name == relative || strings.HasPrefix(name, firmwarePrefix) {
					delete(overlay.firmware, name)
				}
			}
		}
	}
	for name, data := range layer.moduleFiles {
		overlay.moduleFiles[name] = data
	}
	for name := range layer.firmware {
		if name != "" {
			overlay.firmware[name] = struct{}{}
		}
	}
}

func targetKernelFromOverlay(overlay targetOverlay) *TargetKernel {
	var versions []string
	for name := range overlay.moduleFiles {
		if !strings.HasSuffix(name, "/modules.dep") {
			continue
		}
		rest := strings.TrimSuffix(strings.TrimPrefix(name, "usr/lib/modules/"), "/modules.dep")
		if rest != "" && !strings.Contains(rest, "/") {
			versions = append(versions, rest)
		}
	}
	if len(versions) == 0 {
		return nil
	}
	sort.Slice(versions, func(i, j int) bool { return kernelVersionLess(versions[i], versions[j]) })
	version := versions[len(versions)-1]
	prefix := "usr/lib/modules/" + version + "/"
	read := func(name string) string { return string(overlay.moduleFiles[prefix+name]) }
	aliases := parseModuleAliases(read("modules.alias"))
	aliases = append(aliases, parseModuleAliases(read("modules.builtin.alias"))...)
	aliases = append(aliases, parseBuiltinModinfo(read("modules.builtin.modinfo"))...)
	return &TargetKernel{
		KVersion: version,
		Modules:  parseModuleList(read("modules.dep")),
		Builtin:  parseModuleList(read("modules.builtin")),
		Aliases:  aliases,
		Firmware: overlay.firmware,
	}
}

// kernelVersionLess compares digit runs numerically while retaining a stable
// bytewise order for distro suffixes. Kernel directory names are not semver.
func kernelVersionLess(left, right string) bool {
	leftIndex, rightIndex := 0, 0
	for leftIndex < len(left) && rightIndex < len(right) {
		leftDigit := left[leftIndex] >= '0' && left[leftIndex] <= '9'
		rightDigit := right[rightIndex] >= '0' && right[rightIndex] <= '9'
		if leftDigit && rightDigit {
			leftEnd, rightEnd := leftIndex, rightIndex
			for leftEnd < len(left) && left[leftEnd] >= '0' && left[leftEnd] <= '9' {
				leftEnd++
			}
			for rightEnd < len(right) && right[rightEnd] >= '0' && right[rightEnd] <= '9' {
				rightEnd++
			}
			leftNumber, rightNumber := leftIndex, rightIndex
			for leftNumber < leftEnd-1 && left[leftNumber] == '0' {
				leftNumber++
			}
			for rightNumber < rightEnd-1 && right[rightNumber] == '0' {
				rightNumber++
			}
			if leftEnd-leftNumber != rightEnd-rightNumber {
				return leftEnd-leftNumber < rightEnd-rightNumber
			}
			if left[leftNumber:leftEnd] != right[rightNumber:rightEnd] {
				return left[leftNumber:leftEnd] < right[rightNumber:rightEnd]
			}
			leftIndex, rightIndex = leftEnd, rightEnd
			continue
		}
		if left[leftIndex] != right[rightIndex] {
			return left[leftIndex] < right[rightIndex]
		}
		leftIndex++
		rightIndex++
	}
	if leftIndex == len(left) && rightIndex == len(right) {
		return left < right
	}
	return leftIndex == len(left)
}
