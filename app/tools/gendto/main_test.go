package main

import (
	"go/ast"
	"go/parser"
	"os"
	"path/filepath"
	"testing"
)

// These pure helpers drive every field of the generated C# DTOs. They were
// previously exercised only indirectly, through ../../dto_gen_test.go
// running `go run ./tools/gendto` as a subprocess against the real app
// package -- a real functional check, but invisible to `go tool cover`
// because coverage instrumentation does not follow into a subprocess. These
// tests call the functions in-process so gaps in the mapping logic itself
// show up here, at the unit that actually contains them.

func TestToPascalCaseAcronymOverrides(t *testing.T) {
	cases := map[string]string{
		"id":         "Id",
		"osVersion":  "OsVersion",
		"freeDiskGB": "FreeDiskGB",
		"is64Bit":    "Is64Bit",
		"whpx":       "Whpx",
	}
	for in, want := range cases {
		if got := toPascalCase(in); got != want {
			t.Errorf("toPascalCase(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestToPascalCaseGenericCapitalization(t *testing.T) {
	cases := map[string]string{
		"foo":     "Foo",
		"bar":     "Bar",
		"already": "Already",
	}
	for in, want := range cases {
		if got := toPascalCase(in); got != want {
			t.Errorf("toPascalCase(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestToPascalCaseEmptyString(t *testing.T) {
	if got := toPascalCase(""); got != "" {
		t.Errorf("toPascalCase(\"\") = %q, want \"\"", got)
	}
}

func TestMapBasicType(t *testing.T) {
	cases := map[string]string{
		"string":  "string",
		"int":     "int",
		"int64":   "long",
		"float64": "double",
		"bool":    "bool",
		"Custom":  "Custom",
	}
	for in, want := range cases {
		if got := mapBasicType(in); got != want {
			t.Errorf("mapBasicType(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestGoTypeToCSharpSlice(t *testing.T) {
	csType, def := goTypeToCSharp(StructField{IsSlice: true, ElemType: "string"})
	if csType != "List<string>" || def != " = new();" {
		t.Errorf("slice: got (%q, %q)", csType, def)
	}
	csType, def = goTypeToCSharp(StructField{IsSlice: true, ElemType: "int", Omitempty: true})
	if csType != "List<int>?" || def != "" {
		t.Errorf("optional slice: got (%q, %q)", csType, def)
	}
}

func TestGoTypeToCSharpMap(t *testing.T) {
	csType, def := goTypeToCSharp(StructField{IsMap: true, MapKeyType: "string", MapValType: "int"})
	if csType != "Dictionary<string, int>?" || def != "" {
		t.Errorf("map: got (%q, %q)", csType, def)
	}
}

func TestGoTypeToCSharpPointer(t *testing.T) {
	csType, def := goTypeToCSharp(StructField{IsPointer: true, ElemType: "bool"})
	if csType != "bool?" || def != "" {
		t.Errorf("pointer: got (%q, %q)", csType, def)
	}
}

func TestGoTypeToCSharpScalars(t *testing.T) {
	cases := []struct {
		field    StructField
		wantType string
		wantDef  string
	}{
		{StructField{GoType: "string"}, "string", " = string.Empty;"},
		{StructField{GoType: "string", Omitempty: true}, "string?", ""},
		{StructField{GoType: "int"}, "int", ""},
		{StructField{GoType: "int64"}, "long", ""},
		{StructField{GoType: "float64"}, "double", ""},
		{StructField{GoType: "bool"}, "bool", ""},
		{StructField{GoType: "Branding"}, "Branding", ""},
		{StructField{GoType: "Branding", Omitempty: true}, "Branding?", ""},
	}
	for _, c := range cases {
		csType, def := goTypeToCSharp(c.field)
		if csType != c.wantType || def != c.wantDef {
			t.Errorf("goTypeToCSharp(%+v) = (%q, %q), want (%q, %q)", c.field, csType, def, c.wantType, c.wantDef)
		}
	}
}

func parseExpr(t *testing.T, src string) ast.Expr {
	t.Helper()
	expr, err := parser.ParseExpr(src)
	if err != nil {
		t.Fatalf("ParseExpr(%q): %v", src, err)
	}
	return expr
}

func TestParseGoTypeIdent(t *testing.T) {
	goType, isSlice, isMap, isPtr, _, _, elem := parseGoType(parseExpr(t, "int"))
	if goType != "int" || isSlice || isMap || isPtr || elem != "int" {
		t.Errorf("ident: got goType=%q isSlice=%v isMap=%v isPtr=%v elem=%q", goType, isSlice, isMap, isPtr, elem)
	}
}

func TestParseGoTypeSlice(t *testing.T) {
	goType, isSlice, isMap, isPtr, _, _, elem := parseGoType(parseExpr(t, "[]string"))
	if goType != "[]string" || !isSlice || isMap || isPtr || elem != "string" {
		t.Errorf("slice: got goType=%q isSlice=%v isMap=%v isPtr=%v elem=%q", goType, isSlice, isMap, isPtr, elem)
	}
}

func TestParseGoTypeMap(t *testing.T) {
	goType, isSlice, isMap, isPtr, key, val, _ := parseGoType(parseExpr(t, "map[string]int"))
	if goType != "map[string]int" || isSlice || !isMap || isPtr || key != "string" || val != "int" {
		t.Errorf("map: got goType=%q isSlice=%v isMap=%v isPtr=%v key=%q val=%q", goType, isSlice, isMap, isPtr, key, val)
	}
}

func TestParseGoTypePointer(t *testing.T) {
	goType, isSlice, isMap, isPtr, _, _, elem := parseGoType(parseExpr(t, "*bool"))
	if goType != "*bool" || isSlice || isMap || !isPtr || elem != "bool" {
		t.Errorf("pointer: got goType=%q isSlice=%v isMap=%v isPtr=%v elem=%q", goType, isSlice, isMap, isPtr, elem)
	}
}

func TestParseGoTypeSelector(t *testing.T) {
	goType, _, _, _, _, _, elem := parseGoType(parseExpr(t, "time.Duration"))
	if goType != "Duration" || elem != "Duration" {
		t.Errorf("selector: got goType=%q elem=%q, want Duration", goType, elem)
	}
}

func TestFormatXMLDocEmpty(t *testing.T) {
	if got := formatXMLDoc("", "    "); got != "" {
		t.Errorf("formatXMLDoc(\"\", ...) = %q, want \"\"", got)
	}
}

func TestFormatXMLDocEscapesAndWraps(t *testing.T) {
	got := formatXMLDoc("Free space in GB & <required>.", "    ")
	want := "    /// <summary>\n    /// Free space in GB &amp; &lt;required&gt;.\n    /// </summary>\n"
	if got != want {
		t.Errorf("formatXMLDoc mismatch:\ngot:  %q\nwant: %q", got, want)
	}
}

func TestFormatXMLDocStripsSlashPrefixOnEachLine(t *testing.T) {
	got := formatXMLDoc("// Line one\n// Line two", "")
	want := "/// <summary>\n/// Line one\n/// Line two\n/// </summary>\n"
	if got != want {
		t.Errorf("formatXMLDoc mismatch:\ngot:  %q\nwant: %q", got, want)
	}
}

func TestParsePackageStructsSkipsUntaggedAndDashTaggedFields(t *testing.T) {
	dir := t.TempDir()
	src := `package main

// Widget is a thing.
type Widget struct {
	// Name is the widget's name.
	Name string ` + "`json:\"name\"`" + `
	Internal string ` + "`json:\"-\"`" + `
	Untagged string
	Count int ` + "`json:\"count,omitempty\"`" + `
}
`
	if err := os.WriteFile(filepath.Join(dir, "widget.go"), []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}

	structs, err := parsePackageStructs(dir)
	if err != nil {
		t.Fatalf("parsePackageStructs: %v", err)
	}

	def, ok := structs["Widget"]
	if !ok {
		t.Fatalf("Widget not found in parsed structs: %v", structs)
	}
	if def.DocComment == "" {
		t.Error("expected Widget doc comment to be captured")
	}
	if len(def.Fields) != 2 {
		t.Fatalf("expected 2 tagged fields (Internal and Untagged skipped), got %d: %+v", len(def.Fields), def.Fields)
	}

	var nameField, countField *StructField
	for i := range def.Fields {
		switch def.Fields[i].JSONName {
		case "name":
			nameField = &def.Fields[i]
		case "count":
			countField = &def.Fields[i]
		}
	}
	if nameField == nil {
		t.Fatal("expected a field with json name \"name\"")
	}
	if nameField.DocComment == "" {
		t.Error("expected Name field doc comment to be captured")
	}
	if countField == nil {
		t.Fatal("expected a field with json name \"count\"")
	}
	if !countField.Omitempty {
		t.Error("expected count field to be marked omitempty")
	}
}
