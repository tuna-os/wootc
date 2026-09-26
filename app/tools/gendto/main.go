package main

import (
	"bytes"
	"fmt"
	"go/ast"
	"go/doc"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"unicode"
)

// DTOStructs defines the ordered list of Go structs to export to C#.
var DTOStructs = []string{
	"SupportPolicy",
	"SystemInfo",
	"DataPartition",
	"Branding",
	"Image",
	"InstallConfig",
	"ProgressEvent",
	"InstallStatus",
	"UninstallInfo",
	"UninstallOptions",
	"LifecycleState",
	"SessionCandidate",
	"SessionExport",
	"VMEvent",
	"VMCapability",
	"VMState",
	"BundleInfo",
}

type StructField struct {
	Name        string
	GoType      string
	JSONName    string
	Omitempty   bool
	DocComment  string
	IsPointer   bool
	IsSlice     bool
	IsMap       bool
	MapKeyType  string
	MapValType  string
	ElemType    string
}

type StructDef struct {
	Name       string
	DocComment string
	Fields     []StructField
}

func toPascalCase(s string) string {
	if s == "" {
		return ""
	}
	// Common acronym overrides
	acronyms := map[string]string{
		"id":         "Id",
		"osVersion":  "OsVersion",
		"freeDiskGB": "FreeDiskGB",
		"totalDiskGB": "TotalDiskGB",
		"bitLockerOn": "BitLockerOn",
		"bitLockerState": "BitLockerState",
		"isUefi":     "IsUefi",
		"ramGB":      "RamGB",
		"is64Bit":    "Is64Bit",
		"diskSizeGB": "DiskSizeGB",
		"reclaimGB":  "ReclaimGB",
		"freeGB":     "FreeGB",
		"composeFs":  "ComposeFs",
		"mokEnroll":  "MokEnroll",
		"logoDataUri": "LogoDataUri",
		"fontDataUri": "FontDataUri",
		"themeCss":   "ThemeCss",
		"qemuPath":   "QemuPath",
		"whpx":       "Whpx",
	}
	if v, ok := acronyms[s]; ok {
		return v
	}

	runes := []rune(s)
	runes[0] = unicode.ToUpper(runes[0])
	return string(runes)
}

func goTypeToCSharp(f StructField) (string, string) {
	// returns (csharpType, defaultValue)
	switch {
	case f.IsSlice:
		elemType := mapBasicType(f.ElemType)
		if f.Omitempty {
			return fmt.Sprintf("List<%s>?", elemType), ""
		}
		return fmt.Sprintf("List<%s>", elemType), " = new();"

	case f.IsMap:
		kt := mapBasicType(f.MapKeyType)
		vt := mapBasicType(f.MapValType)
		return fmt.Sprintf("Dictionary<%s, %s>?", kt, vt), ""

	case f.IsPointer:
		elemType := mapBasicType(f.ElemType)
		return fmt.Sprintf("%s?", elemType), ""

	default:
		switch f.GoType {
		case "string":
			if f.Omitempty {
				return "string?", ""
			}
			return "string", " = string.Empty;"
		case "int":
			return "int", ""
		case "int64":
			return "long", ""
		case "float64":
			return "double", ""
		case "bool":
			return "bool", ""
		default:
			// Named struct type
			if f.Omitempty {
				return f.GoType + "?", ""
			}
			return f.GoType, ""
		}
	}
}

func mapBasicType(t string) string {
	switch t {
	case "string":
		return "string"
	case "int":
		return "int"
	case "int64":
		return "long"
	case "float64":
		return "double"
	case "bool":
		return "bool"
	default:
		return t
	}
}

func parseGoType(expr ast.Expr) (goType string, isSlice bool, isMap bool, isPtr bool, keyType string, valType string, elemType string) {
	switch t := expr.(type) {
	case *ast.Ident:
		return t.Name, false, false, false, "", "", t.Name
	case *ast.ArrayType:
		subType, _, _, _, _, _, _ := parseGoType(t.Elt)
		return "[]" + subType, true, false, false, "", "", subType
	case *ast.MapType:
		kt, _, _, _, _, _, _ := parseGoType(t.Key)
		vt, _, _, _, _, _, _ := parseGoType(t.Value)
		return fmt.Sprintf("map[%s]%s", kt, vt), false, true, false, kt, vt, ""
	case *ast.StarExpr:
		subType, _, _, _, _, _, _ := parseGoType(t.X)
		return "*" + subType, false, false, true, "", "", subType
	case *ast.SelectorExpr:
		return t.Sel.Name, false, false, false, "", "", t.Sel.Name
	default:
		return fmt.Sprintf("%v", expr), false, false, false, "", "", ""
	}
}

func parsePackageStructs(appDir string) (map[string]StructDef, error) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, appDir, func(fi os.FileInfo) bool {
		// skip tests and tools
		return !strings.HasSuffix(fi.Name(), "_test.go") && !strings.Contains(fi.Name(), "gen_")
	}, parser.ParseComments)
	if err != nil {
		return nil, err
	}

	result := make(map[string]StructDef)

	for _, pkg := range pkgs {
		docPkg := doc.New(pkg, "", doc.AllDecls)
		for _, typ := range docPkg.Types {
			// Check if typ is a struct
			for _, spec := range typ.Decl.Specs {
				typeSpec, ok := spec.(*ast.TypeSpec)
				if !ok {
					continue
				}
				structType, ok := typeSpec.Type.(*ast.StructType)
				if !ok {
					continue
				}

				def := StructDef{
					Name:       typeSpec.Name.Name,
					DocComment: strings.TrimSpace(typ.Doc),
				}

				if structType.Fields != nil {
					for _, field := range structType.Fields.List {
						var fieldDoc string
						if field.Doc != nil {
							fieldDoc = strings.TrimSpace(field.Doc.Text())
						} else if field.Comment != nil {
							fieldDoc = strings.TrimSpace(field.Comment.Text())
						}

						goType, isSlice, isMap, isPtr, kType, vType, eType := parseGoType(field.Type)

						tagVal := ""
						if field.Tag != nil {
							tagVal = field.Tag.Value
							tagVal = strings.Trim(tagVal, "`")
						}
						jsonTag := reflect.StructTag(tagVal).Get("json")
						if jsonTag == "" || jsonTag == "-" {
							continue
						}
						parts := strings.Split(jsonTag, ",")
						jsonName := parts[0]
						omitempty := false
						for _, p := range parts[1:] {
							if p == "omitempty" {
								omitempty = true
							}
						}

						for _, name := range field.Names {
							def.Fields = append(def.Fields, StructField{
								Name:        name.Name,
								GoType:      goType,
								JSONName:    jsonName,
								Omitempty:   omitempty,
								DocComment:  fieldDoc,
								IsPointer:   isPtr,
								IsSlice:     isSlice,
								IsMap:       isMap,
								MapKeyType:  kType,
								MapValType:  vType,
								ElemType:    eType,
							})
						}
					}
				}

				result[def.Name] = def
			}
		}
	}

	return result, nil
}

func formatXMLDoc(comment string, indent string) string {
	if comment == "" {
		return ""
	}
	lines := strings.Split(comment, "\n")
	var sb strings.Builder
	sb.WriteString(indent + "/// <summary>\n")
	for _, l := range lines {
		clean := strings.TrimSpace(l)
		clean = strings.TrimPrefix(clean, "//")
		clean = strings.TrimSpace(clean)
		clean = strings.ReplaceAll(clean, "&", "&amp;")
		clean = strings.ReplaceAll(clean, "<", "&lt;")
		clean = strings.ReplaceAll(clean, ">", "&gt;")
		if clean != "" {
			sb.WriteString(indent + "/// " + clean + "\n")
		}
	}
	sb.WriteString(indent + "/// </summary>\n")
	return sb.String()
}

func GenerateCSharpDTOs(appDir string) (string, error) {
	structs, err := parsePackageStructs(appDir)
	if err != nil {
		return "", err
	}

	var buf bytes.Buffer
	buf.WriteString("// <auto-generated>\n")
	buf.WriteString("// This code was generated by go generate (app/tools/gendto).\n")
	buf.WriteString("// Do not edit this file directly.\n")
	buf.WriteString("// </auto-generated>\n\n")
	buf.WriteString("#nullable enable\n\n")
	buf.WriteString("using System;\n")
	buf.WriteString("using System.Collections.Generic;\n")
	buf.WriteString("using System.Text.Json.Serialization;\n\n")
	buf.WriteString("namespace Wootc.Shell.Engine;\n\n")

	for _, structName := range DTOStructs {
		def, ok := structs[structName]
		if !ok {
			return "", fmt.Errorf("struct %s not found in %s", structName, appDir)
		}

		if def.DocComment != "" {
			buf.WriteString(formatXMLDoc(def.DocComment, ""))
		}
		buf.WriteString(fmt.Sprintf("public class %s\n{\n", def.Name))

		for i, field := range def.Fields {
			if i > 0 {
				buf.WriteString("\n")
			}
			if field.DocComment != "" {
				buf.WriteString(formatXMLDoc(field.DocComment, "    "))
			}
			csharpType, defaultVal := goTypeToCSharp(field)
			propName := toPascalCase(field.JSONName)
			if propName == "" {
				propName = field.Name
			}

			buf.WriteString(fmt.Sprintf("    [JsonPropertyName(%q)]\n", field.JSONName))
			buf.WriteString(fmt.Sprintf("    public %s %s { get; set; }%s\n", csharpType, propName, defaultVal))
		}

		buf.WriteString("}\n\n")
	}

	return strings.TrimRight(buf.String(), "\n") + "\n", nil
}

func main() {
	appDir := "."
	if len(os.Args) > 1 {
		appDir = os.Args[1]
	} else {
		// Detect app directory if run from app/tools/gendto or app/
		if _, err := os.Stat("app.go"); err == nil {
			appDir = "."
		} else if _, err := os.Stat("../../app.go"); err == nil {
			appDir = "../.."
		}
	}

	content, err := GenerateCSharpDTOs(appDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gendto error: %v\n", err)
		os.Exit(1)
	}

	outPath := filepath.Join(appDir, "..", "shell", "Wootc.Shell", "Engine", "Dto.cs")
	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir error: %v\n", err)
		os.Exit(1)
	}

	if err := os.WriteFile(outPath, []byte(content), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "write error: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("Generated %s\n", outPath)
}
