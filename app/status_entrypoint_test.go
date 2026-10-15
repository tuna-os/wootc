package main

import (
	"bytes"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// Execute the production main initialization statement with a controlled
// mutator. The fixture cannot access installer state: its only mutator writes
// a marker inside this test's private directory. No application main runs.
func TestStatusEntrypointActualMainWiring(t *testing.T) {
	fs := token.NewFileSet()
	mainFile, err := parser.ParseFile(fs, "main.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	helperFile, err := parser.ParseFile(fs, "status_location.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var body *ast.BlockStmt
	for _, decl := range mainFile.Decls {
		if f, ok := decl.(*ast.FuncDecl); ok && f.Name.Name == "main" {
			for _, statement := range f.Body.List {
				branch, ok := statement.(*ast.IfStmt)
				if !ok {
					continue
				}
				assignment, ok := branch.Init.(*ast.AssignStmt)
				if !ok || len(assignment.Rhs) != 1 {
					continue
				}
				call, ok := assignment.Rhs[0].(*ast.CallExpr)
				if !ok {
					continue
				}
				name, ok := call.Fun.(*ast.Ident)
				if ok && (name.Name == "initializeStateTrustForInvocation" || name.Name == "initializeStateTrust") {
					if body != nil {
						t.Fatal("ambiguous main initialization")
					}
					body = &ast.BlockStmt{List: []ast.Stmt{statement}}
				}
			}
		}
	}
	if body == nil {
		t.Fatal("main entrypoint absent")
	}
	var source bytes.Buffer
	source.WriteString("package main\nimport (\"os\")\n")
	fixtureMain := &ast.FuncDecl{Name: ast.NewIdent("main"), Type: &ast.FuncType{Params: &ast.FieldList{}}, Body: body}
	if err := format.Node(&source, fs, fixtureMain); err != nil {
		t.Fatal(err)
	}
	for _, decl := range helperFile.Decls {
		if f, ok := decl.(*ast.FuncDecl); ok && (f.Name.Name == "initializeStateTrustForInvocation" || f.Name.Name == "initializeStateTrustForInvocationWith") {
			source.WriteByte('\n')
			if err := format.Node(&source, fs, f); err != nil {
				t.Fatal(err)
			}
		}
	}
	source.WriteString("\nfunc initializeStateTrust() error { return os.WriteFile(os.Getenv(\"WOOTC_ENTRYPOINT_MARKER\"), []byte(\"mutation observed\"), 0600) }\nfunc reportStateTrustFailure(error) {}\n")
	root := t.TempDir()
	sourcePath := filepath.Join(root, "entrypoint.go")
	if err := os.WriteFile(sourcePath, source.Bytes(), 0600); err != nil {
		t.Fatal(err)
	}
	binary := filepath.Join(root, "entrypoint.exe")
	build := exec.Command("go", "build", "-o", binary, sourcePath)
	build.Env = append(os.Environ(), "CGO_ENABLED=0")
	if out, err := build.CombinedOutput(); err != nil {
		t.Fatalf("entrypoint fixture build: %v %s", err, out)
	}
	for _, arg := range []string{"status", "install", "serve", "recover", ""} {
		marker := filepath.Join(root, "marker-"+arg)
		args := []string{}
		if arg != "" {
			args = append(args, arg)
		}
		command := exec.Command(binary, args...)
		command.Env = append(os.Environ(), "WOOTC_ENTRYPOINT_MARKER="+marker)
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("entrypoint %q: %v %s", arg, err, out)
		}
		data, err := os.ReadFile(marker)
		if arg == "status" {
			if !os.IsNotExist(err) {
				t.Fatalf("actual main invoked status mutator: data=%q err=%v", data, err)
			}
		} else if err != nil || string(data) != "mutation observed" {
			t.Fatalf("actual main lost %q mutator: %v", arg, err)
		}
	}
}
