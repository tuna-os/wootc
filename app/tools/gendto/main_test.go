package main

import (
	"go/ast"
	"go/parser"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestToPascalCase(t *testing.T) {
	cases := []struct{ in, want string }{
		{"", ""},
		{"id", "Id"},
		{"osVersion", "OsVersion"},
		{"freeDiskGB", "FreeDiskGB"},
		{"totalDiskGB", "TotalDiskGB"},
		{"bitLockerOn", "BitLockerOn"},
		{"bitLockerState", "BitLockerState"},
		{"isUefi", "IsUefi"},
		{"ramGB", "RamGB"},
		{"is64Bit", "Is64Bit"},
		{"diskSizeGB", "DiskSizeGB"},
		{"reclaimGB", "ReclaimGB"},
		{"freeGB", "FreeGB"},
		{"composeFs", "ComposeFs"},
		{"mokEnroll", "MokEnroll"},
		{"logoDataUri", "LogoDataUri"},
		{"fontDataUri", "FontDataUri"},
		{"themeCss", "ThemeCss"},
		{"qemuPath", "QemuPath"},
		{"whpx", "Whpx"},
		{"name", "Name"},
		{"progress", "Progress"},
	}
	for _, c := range cases {
		if got := toPascalCase(c.in); got != c.want {
			t.Errorf("toPascalCase(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestGoTypeToCSharp(t *testing.T) {
	cases := []struct {
		name        string
		f           StructField
		wantType    string
		wantDefault string
	}{
		{"slice of string", StructField{IsSlice: true, ElemType: "string"}, "List<string>", " = new();"},
		{"slice omitempty", StructField{IsSlice: true, ElemType: "string", Omitempty: true}, "List<string>?", ""},
		{"slice of named type", StructField{IsSlice: true, ElemType: "Image"}, "List<Image>", " = new();"},
		{"map", StructField{IsMap: true, MapKeyType: "string", MapValType: "int"}, "Dictionary<string, int>?", ""},
		{"pointer", StructField{IsPointer: true, ElemType: "Branding"}, "Branding?", ""},
		{"string required", StructField{GoType: "string"}, "string", " = string.Empty;"},
		{"string omitempty", StructField{GoType: "string", Omitempty: true}, "string?", ""},
		{"int", StructField{GoType: "int"}, "int", ""},
		{"int64", StructField{GoType: "int64"}, "long", ""},
		{"float64", StructField{GoType: "float64"}, "double", ""},
		{"bool", StructField{GoType: "bool"}, "bool", ""},
		{"named struct required", StructField{GoType: "SystemInfo"}, "SystemInfo", ""},
		{"named struct omitempty", StructField{GoType: "SystemInfo", Omitempty: true}, "SystemInfo?", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			gotType, gotDefault := goTypeToCSharp(c.f)
			if gotType != c.wantType || gotDefault != c.wantDefault {
				t.Errorf("goTypeToCSharp(%+v) = (%q, %q), want (%q, %q)", c.f, gotType, gotDefault, c.wantType, c.wantDefault)
			}
		})
	}
}

func TestMapBasicType(t *testing.T) {
	cases := []struct{ in, want string }{
		{"string", "string"},
		{"int", "int"},
		{"int64", "long"},
		{"float64", "double"},
		{"bool", "bool"},
		{"Branding", "Branding"},
	}
	for _, c := range cases {
		if got := mapBasicType(c.in); got != c.want {
			t.Errorf("mapBasicType(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func parseExpr(t *testing.T, src string) ast.Expr {
	t.Helper()
	expr, err := parser.ParseExpr(src)
	if err != nil {
		t.Fatalf("ParseExpr(%q) failed: %v", src, err)
	}
	return expr
}

func TestParseGoType(t *testing.T) {
	t.Run("ident", func(t *testing.T) {
		goType, isSlice, isMap, isPtr, keyType, valType, elemType := parseGoType(parseExpr(t, "string"))
		if goType != "string" || isSlice || isMap || isPtr || keyType != "" || valType != "" || elemType != "string" {
			t.Errorf("unexpected result: %q %v %v %v %q %q %q", goType, isSlice, isMap, isPtr, keyType, valType, elemType)
		}
	})
	t.Run("array", func(t *testing.T) {
		goType, isSlice, isMap, isPtr, _, _, elemType := parseGoType(parseExpr(t, "[]string"))
		if goType != "[]string" || !isSlice || isMap || isPtr || elemType != "string" {
			t.Errorf("unexpected result: %q %v %v %v %q", goType, isSlice, isMap, isPtr, elemType)
		}
	})
	t.Run("map", func(t *testing.T) {
		goType, isSlice, isMap, isPtr, keyType, valType, _ := parseGoType(parseExpr(t, "map[string]int"))
		if goType != "map[string]int" || isSlice || !isMap || isPtr || keyType != "string" || valType != "int" {
			t.Errorf("unexpected result: %q %v %v %v %q %q", goType, isSlice, isMap, isPtr, keyType, valType)
		}
	})
	t.Run("pointer", func(t *testing.T) {
		goType, isSlice, isMap, isPtr, _, _, elemType := parseGoType(parseExpr(t, "*Branding"))
		if goType != "*Branding" || isSlice || isMap || !isPtr || elemType != "Branding" {
			t.Errorf("unexpected result: %q %v %v %v %q", goType, isSlice, isMap, isPtr, elemType)
		}
	})
	t.Run("selector", func(t *testing.T) {
		goType, isSlice, isMap, isPtr, _, _, elemType := parseGoType(parseExpr(t, "time.Duration"))
		if goType != "Duration" || isSlice || isMap || isPtr || elemType != "Duration" {
			t.Errorf("unexpected result: %q %v %v %v %q", goType, isSlice, isMap, isPtr, elemType)
		}
	})
	t.Run("unsupported falls back to Sprintf", func(t *testing.T) {
		expr, err := parser.ParseExpr("func()")
		if err != nil {
			t.Fatalf("ParseExpr failed: %v", err)
		}
		goType, isSlice, isMap, isPtr, _, _, _ := parseGoType(expr)
		if isSlice || isMap || isPtr || goType == "" {
			t.Errorf("unexpected result for func type: %q %v %v %v", goType, isSlice, isMap, isPtr)
		}
	})
}

func TestFormatXMLDoc(t *testing.T) {
	if got := formatXMLDoc("", "  "); got != "" {
		t.Errorf("formatXMLDoc(empty) = %q, want empty string", got)
	}

	got := formatXMLDoc("// Free disk space in GB.\n// Second line.", "    ")
	want := "    /// <summary>\n    /// Free disk space in GB.\n    /// Second line.\n    /// </summary>\n"
	if got != want {
		t.Errorf("formatXMLDoc() = %q, want %q", got, want)
	}

	escaped := formatXMLDoc("a < b && b > c", "")
	if !strings.Contains(escaped, "&lt;") || !strings.Contains(escaped, "&gt;") || !strings.Contains(escaped, "&amp;") {
		t.Errorf("formatXMLDoc() did not escape XML special characters: %q", escaped)
	}
}

func writeFixtureFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatalf("failed to write fixture %s: %v", name, err)
	}
}

func TestParsePackageStructsSkipsTestsAndGenFiles(t *testing.T) {
	dir := t.TempDir()
	writeFixtureFile(t, dir, "types.go", `package main

// Widget describes a thing.
type Widget struct {
	// Name is the widget's name.
	Name string `+"`json:\"name\"`"+`
	Hidden string `+"`json:\"-\"`"+`
	NoTag  string
}
`)
	writeFixtureFile(t, dir, "types_test.go", `package main

type ShouldBeSkipped struct {
	X string `+"`json:\"x\"`"+`
}
`)
	writeFixtureFile(t, dir, "gen_extra.go", `package main

type AlsoSkipped struct {
	Y string `+"`json:\"y\"`"+`
}
`)

	structs, err := parsePackageStructs(dir)
	if err != nil {
		t.Fatalf("parsePackageStructs failed: %v", err)
	}

	if _, ok := structs["ShouldBeSkipped"]; ok {
		t.Errorf("expected _test.go file to be skipped")
	}
	if _, ok := structs["AlsoSkipped"]; ok {
		t.Errorf("expected gen_ file to be skipped")
	}

	widget, ok := structs["Widget"]
	if !ok {
		t.Fatalf("expected Widget struct to be parsed")
	}
	if widget.DocComment == "" {
		t.Errorf("expected Widget doc comment to be captured")
	}
	if len(widget.Fields) != 1 {
		t.Fatalf("expected exactly 1 field (json:\"-\" and untagged fields excluded), got %d: %+v", len(widget.Fields), widget.Fields)
	}
	if widget.Fields[0].Name != "Name" || widget.Fields[0].JSONName != "name" {
		t.Errorf("unexpected field: %+v", widget.Fields[0])
	}
	if widget.Fields[0].DocComment == "" {
		t.Errorf("expected field doc comment to be captured")
	}
}

func TestGenerateCSharpDTOs(t *testing.T) {
	dir := t.TempDir()
	writeFixtureFile(t, dir, "types.go", `package main

// Widget is a simple test struct.
type Widget struct {
	Name string `+"`json:\"name\"`"+`
	Size int `+"`json:\"size,omitempty\"`"+`
}
`)

	orig := DTOStructs
	DTOStructs = []string{"Widget"}
	defer func() { DTOStructs = orig }()

	out, err := GenerateCSharpDTOs(dir)
	if err != nil {
		t.Fatalf("GenerateCSharpDTOs failed: %v", err)
	}
	for _, want := range []string{
		"// <auto-generated>",
		"namespace Wootc.Shell.Engine;",
		"public class Widget",
		`[JsonPropertyName("name")]`,
		"public string Name { get; set; } = string.Empty;",
		`[JsonPropertyName("size")]`,
		"public int Size { get; set; }",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("generated output missing %q\nfull output:\n%s", want, out)
		}
	}
}

func TestGenerateCSharpDTOsMissingStruct(t *testing.T) {
	dir := t.TempDir()
	writeFixtureFile(t, dir, "types.go", `package main

type Widget struct {
	Name string `+"`json:\"name\"`"+`
}
`)

	orig := DTOStructs
	DTOStructs = []string{"DoesNotExist"}
	defer func() { DTOStructs = orig }()

	if _, err := GenerateCSharpDTOs(dir); err == nil {
		t.Fatalf("expected error for missing struct, got nil")
	}
}

func TestGenerateCSharpDTOsInvalidDir(t *testing.T) {
	if _, err := GenerateCSharpDTOs(filepath.Join(t.TempDir(), "does-not-exist")); err == nil {
		t.Fatalf("expected error for nonexistent directory, got nil")
	}
}
