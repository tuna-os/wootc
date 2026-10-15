package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"path"
	"regexp"
	"strings"
)

// Recompute ancestry from measured graph edges. Guest verdicts are not authority.
type vmGuestBlock struct {
	Name     string         `json:"name"`
	KName    string         `json:"kname"`
	Type     string         `json:"type"`
	Major    string         `json:"maj:min"`
	UUID     string         `json:"uuid"`
	PTUUID   string         `json:"ptuuid"`
	Children []vmGuestBlock `json:"children"`
	PKName   string         `json:"pkname"`
}
type vmGuestMount struct {
	Target   string         `json:"target"`
	Source   string         `json:"source"`
	FSType   string         `json:"fstype"`
	Major    string         `json:"maj:min"`
	Options  string         `json:"options"`
	UUID     string         `json:"uuid"`
	Children []vmGuestMount `json:"children"`
}
type vmGuestLoop struct {
	Name     string `json:"name"`
	Major    string `json:"maj:min"`
	BackFile string `json:"back-file"`
}
type vmGuestGraph struct {
	nodes        map[string]vmGuestBlock
	aliases      map[string]string
	parents      map[string]map[string]bool
	mounts       map[string]vmGuestMount
	loops, paths map[string]string
	btrfs        map[string][]string
	target       string
}

var vmGuestMajor = regexp.MustCompile(`^[0-9]+:[0-9]+$`)

func vmGuestGraphText(encoded string) ([]byte, error) {
	b, e := base64.StdEncoding.DecodeString(encoded)
	if e != nil || len(b) > 256<<10 {
		return nil, fmt.Errorf("measured graph encoding unavailable")
	}
	return b, nil
}
func vmGuestGraphJSON(encoded string, target any) error {
	b, e := vmGuestGraphText(encoded)
	if e != nil {
		return e
	}
	if _, e = decodeQMPObject(b); e != nil {
		return e
	}
	return json.Unmarshal(b, target)
}
func verifyVMGuestRoot(root vmGuestProbeRoot, diskID string) error {
	g := vmGuestGraph{nodes: map[string]vmGuestBlock{}, aliases: map[string]string{}, parents: map[string]map[string]bool{}, mounts: map[string]vmGuestMount{}, loops: map[string]string{}, paths: map[string]string{}, btrfs: map[string][]string{}}
	var blocks struct {
		Rows []vmGuestBlock `json:"blockdevices"`
	}
	var mounts struct {
		Rows []vmGuestMount `json:"filesystems"`
	}
	var loops struct {
		Rows []vmGuestLoop `json:"loopdevices"`
	}
	if e := vmGuestGraphJSON(root.Measurements["BLOCKS"], &blocks); e != nil {
		return e
	}
	if e := vmGuestGraphJSON(root.Measurements["MOUNTS"], &mounts); e != nil {
		return e
	}
	if e := vmGuestGraphJSON(root.Measurements["LOOPS"], &loops); e != nil {
		return e
	}
	selected := map[string]bool{}
	var visit func([]vmGuestBlock, string, int) error
	visit = func(rows []vmGuestBlock, parent string, depth int) error {
		if rows == nil || depth > 32 {
			return fmt.Errorf("block inventory unavailable")
		}
		for _, r := range rows {
			if !vmGuestMajor.MatchString(r.Major) || !strings.HasPrefix(r.Name, "/dev/") || !vmGuestAbsolute(r.Name) || !strings.HasPrefix(r.KName, "/dev/") || !vmGuestAbsolute(r.KName) || r.Type == "" {
				return fmt.Errorf("invalid block identity")
			}
			if len(g.nodes) >= 1024 {
				return fmt.Errorf("block bound")
			}
			if old, ok := g.nodes[r.Major]; ok && (old.Name != r.Name || old.KName != r.KName || old.Type != r.Type || old.UUID != r.UUID || old.PTUUID != r.PTUUID) {
				return fmt.Errorf("conflicting block identity")
			}
			g.nodes[r.Major] = r
			for _, a := range []string{r.Name, r.KName} {
				if old, ok := g.aliases[a]; ok && old != r.Major {
					return fmt.Errorf("ambiguous block alias")
				}
				g.aliases[a] = r.Major
			}
			if g.parents[r.Major] == nil {
				g.parents[r.Major] = map[string]bool{}
			}
			if parent != "" {
				g.parents[r.Major][parent] = true
			}
			if r.Type == "disk" && r.PTUUID == diskID {
				selected[r.Major] = true
			}
			if r.Children != nil {
				if e := visit(r.Children, r.Major, depth+1); e != nil {
					return e
				}
			}
		}
		return nil
	}
	if e := visit(blocks.Rows, "", 0); e != nil {
		return e
	}
	for major, node := range g.nodes {
		if node.PKName != "" {
			parent := g.aliases[node.PKName]
			if parent == "" || !g.parents[major][parent] {
				return fmt.Errorf("measured parent name disagrees with graph edge")
			}
		}
	}
	g.target = g.aliases[root.Target]
	if len(selected) != 1 || !selected[g.target] || g.nodes[g.target].Type != "disk" {
		return fmt.Errorf("unique selected GPT disk not measured")
	}
	var mountVisit func([]vmGuestMount, int) error
	mountVisit = func(rows []vmGuestMount, depth int) error {
		if rows == nil || depth > 32 {
			return fmt.Errorf("mount inventory unavailable")
		}
		for _, r := range rows {
			if !vmGuestAbsolute(r.Target) || r.Source == "" || r.FSType == "" || r.Options == "" || !vmGuestMajor.MatchString(r.Major) {
				return fmt.Errorf("incomplete mount observation")
			}
			if _, ok := g.mounts[r.Target]; ok || len(g.mounts) >= 4096 {
				return fmt.Errorf("ambiguous mount inventory")
			}
			g.mounts[r.Target] = r
			if r.Children != nil {
				if e := mountVisit(r.Children, depth+1); e != nil {
					return e
				}
			}
		}
		return nil
	}
	if e := mountVisit(mounts.Rows, 0); e != nil {
		return e
	}
	if loops.Rows == nil || len(loops.Rows) > 512 {
		return fmt.Errorf("loop inventory unavailable")
	}
	for _, r := range loops.Rows {
		if _, ok := g.loops[r.Major]; ok || g.aliases[r.Name] != r.Major || !vmGuestAbsolute(r.BackFile) {
			return fmt.Errorf("ambiguous loop inventory")
		}
		g.loops[r.Major] = r.BackFile
	}
	for _, key := range []string{"PATHS", "BTRFS"} {
		b, e := vmGuestGraphText(root.Measurements[key])
		if e != nil {
			return e
		}
		s := string(b)
		if s == "" {
			continue
		}
		for _, line := range strings.Split(s, "\n") {
			fields := strings.Split(line, "\t")
			if key == "PATHS" {
				if len(fields) != 2 || len(g.paths) >= 512 {
					return fmt.Errorf("invalid resolved path inventory")
				}
				if _, ok := g.paths[fields[0]]; ok {
					return fmt.Errorf("duplicate path")
				}
				g.paths[fields[0]] = fields[1]
			} else {
				if len(fields) != 3 || !vmGuestUUID.MatchString(fields[0]) || len(g.btrfs) >= 128 {
					return fmt.Errorf("invalid Btrfs inventory")
				}
				if _, ok := g.btrfs[fields[0]]; ok {
					return fmt.Errorf("duplicate Btrfs identity")
				}
				if fields[1] == "1" {
					g.btrfs[fields[0]] = strings.Split(fields[2], ",")
				} else if fields[1] == "0" {
					g.btrfs[fields[0]] = nil
				} else {
					return fmt.Errorf("invalid Btrfs validity")
				}
			}
		}
	}
	return g.verifyRoot()
}
func vmGuestAbsolute(s string) bool {
	return strings.HasPrefix(s, "/") && path.Clean(s) == s && !strings.ContainsAny(s, "\\\t\r\n ")
}
func cloneGuestSeen(s map[string]bool) map[string]bool {
	r := map[string]bool{}
	for k, v := range s {
		r[k] = v
	}
	return r
}
func (g *vmGuestGraph) mountFor(p string) (vmGuestMount, error) {
	resolved, ok := g.paths[p]
	if !ok || !vmGuestAbsolute(resolved) {
		return vmGuestMount{}, fmt.Errorf("resolved projection unavailable")
	}
	best := ""
	for t := range g.mounts {
		if t == "/" || t == resolved || strings.HasPrefix(resolved, t+"/") {
			if len(t) > len(best) {
				best = t
			}
		}
	}
	if best == "" {
		return vmGuestMount{}, fmt.Errorf("projection mount unavailable")
	}
	return g.mounts[best], nil
}
func (g *vmGuestGraph) disk(major string, projected bool, seen map[string]bool) (map[string]bool, error) {
	if seen[major] {
		return nil, fmt.Errorf("cyclic backing")
	}
	node, ok := g.nodes[major]
	if !ok {
		return nil, fmt.Errorf("block backing unavailable")
	}
	seen = cloneGuestSeen(seen)
	seen[major] = true
	switch node.Type {
	case "loop":
		if !projected {
			return nil, fmt.Errorf("root is loop backed")
		}
		p, ok := g.loops[major]
		if !ok {
			return nil, fmt.Errorf("loop backing unavailable")
		}
		row, e := g.mountFor(p)
		if e != nil {
			return nil, e
		}
		return g.mount(row, false, seen)
	case "disk":
		if len(g.parents[major]) != 0 {
			return nil, fmt.Errorf("whole disk parents")
		}
		return map[string]bool{major: true}, nil
	case "part", "crypt", "lvm", "dm", "mpath", "md", "raid0", "raid1", "raid4", "raid5", "raid6", "raid10":
	default:
		return nil, fmt.Errorf("unknown block layer")
	}
	if len(g.parents[major]) == 0 {
		return nil, fmt.Errorf("missing block parents")
	}
	out := map[string]bool{}
	for p := range g.parents[major] {
		a, e := g.disk(p, projected, seen)
		if e != nil {
			return nil, e
		}
		for k := range a {
			out[k] = true
		}
	}
	return out, nil
}
func (g *vmGuestGraph) mount(row vmGuestMount, projected bool, seen map[string]bool) (map[string]bool, error) {
	base := strings.SplitN(row.Source, "[", 2)[0]
	physical := g.aliases[base]
	if row.FSType == "btrfs" {
		members := g.btrfs[row.UUID]
		if physical == "" || row.UUID == "" || g.nodes[physical].UUID != row.UUID || len(members) == 0 {
			return nil, fmt.Errorf("Btrfs membership unavailable")
		}
		out := map[string]bool{}
		unique := map[string]bool{}
		for _, m := range members {
			if unique[m] || !vmGuestMajor.MatchString(m) {
				return nil, fmt.Errorf("ambiguous Btrfs membership")
			}
			unique[m] = true
			if g.nodes[m].UUID != row.UUID {
				return nil, fmt.Errorf("Btrfs member filesystem identity disagrees")
			}
			a, e := g.disk(m, false, seen)
			if e != nil {
				return nil, e
			}
			for k := range a {
				out[k] = true
			}
		}
		if !unique[physical] {
			return nil, fmt.Errorf("Btrfs source not current member")
		}
		return out, nil
	}
	if physical != row.Major {
		return nil, fmt.Errorf("mount source identity mismatch")
	}
	return g.disk(row.Major, projected, seen)
}
func (g *vmGuestGraph) require(row vmGuestMount) error {
	a, e := g.mount(row, row.FSType == "erofs", map[string]bool{})
	if e != nil {
		return e
	}
	if len(a) != 1 || !a[g.target] {
		return fmt.Errorf("current backing outside selected target")
	}
	return nil
}
func (g *vmGuestGraph) verifyRoot() error {
	row, ok := g.mounts["/"]
	if !ok {
		return fmt.Errorf("current root unavailable")
	}
	if row.FSType != "overlay" {
		return g.require(row)
	}
	layers := map[string]string{}
	for _, o := range strings.Split(row.Options, ",") {
		k, v, has := strings.Cut(o, "=")
		raw := k
		k = strings.TrimRight(k, "+")
		switch k {
		case "lowerdir", "datadir", "upperdir", "workdir":
			if !has || v == "" || layers[k] != "" || strings.ContainsAny(v, "\\ \t\r\n") || (raw != k && raw != k+"+") || (raw != k && k != "lowerdir" && k != "datadir") {
				return fmt.Errorf("ambiguous overlay layer")
			}
			layers[k] = v
		}
	}
	if layers["lowerdir"] == "" || (layers["upperdir"] == "") != (layers["workdir"] == "") {
		return fmt.Errorf("incomplete overlay content")
	}
	paths := []string{}
	for k, v := range layers {
		if k == "lowerdir" && strings.Contains(v, "::") {
			if strings.Count(v, "::") != 1 {
				return fmt.Errorf("ambiguous data layer")
			}
			left, right, _ := strings.Cut(v, "::")
			if left == "" || right == "" {
				return fmt.Errorf("empty data layer")
			}
			v = left + ":" + right
		}
		parts := strings.Split(v, ":")
		if (k == "upperdir" || k == "workdir") && len(parts) != 1 {
			return fmt.Errorf("invalid writable layer")
		}
		for _, p := range parts {
			if !vmGuestAbsolute(p) {
				return fmt.Errorf("invalid layer path")
			}
			paths = append(paths, p)
		}
	}
	if len(paths) > 32 {
		return fmt.Errorf("projection bound")
	}
	if layers["upperdir"] != "" {
		u, e := g.mountFor(layers["upperdir"])
		if e != nil {
			return e
		}
		w, e := g.mountFor(layers["workdir"])
		if e != nil {
			return e
		}
		if u.Major != w.Major || u.Source != w.Source {
			return fmt.Errorf("writable layers disagree")
		}
	}
	for _, p := range paths {
		r, e := g.mountFor(p)
		if e != nil {
			return e
		}
		if r.Target == "/" {
			return fmt.Errorf("root projection through itself")
		}
		if e = g.require(r); e != nil {
			return e
		}
	}
	return nil
}
