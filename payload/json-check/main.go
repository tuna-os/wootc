// wootc-json-check rejects ambiguous or unbounded metadata before jq consumes it.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"unicode/utf8"
)

func value(d *json.Decoder, depth int, count *int, path string) error {
	*count++
	if depth > 32 || *count > 16384 {
		return fmt.Errorf("JSON structure exceeds bound")
	}
	t, err := d.Token()
	if err != nil {
		return err
	}
	if path == "/config/size" || path == "/layers/#/size" || path == "/manifests/#/size" {
		n, ok := t.(json.Number)
		if !ok || !regexp.MustCompile(`^(0|[1-9][0-9]*)$`).MatchString(string(n)) {
			return fmt.Errorf("invalid descriptor size")
		}
	}
	delim, ok := t.(json.Delim)
	if !ok {
		return nil
	}
	switch delim {
	case '{':
		keys := map[string]bool{}
		for d.More() {
			token, err := d.Token()
			if err != nil {
				return err
			}
			key, ok := token.(string)
			if !ok || keys[key] {
				return fmt.Errorf("duplicate or invalid JSON key")
			}
			keys[key] = true
			if err := value(d, depth+1, count, path+"/"+key); err != nil {
				return err
			}
		}
		token, err := d.Token()
		if err != nil || token != json.Delim('}') {
			return fmt.Errorf("invalid JSON object end")
		}
	case '[':
		for d.More() {
			if err := value(d, depth+1, count, path+"/#"); err != nil {
				return err
			}
		}
		token, err := d.Token()
		if err != nil || token != json.Delim(']') {
			return fmt.Errorf("invalid JSON array end")
		}
	default:
		return fmt.Errorf("unexpected JSON delimiter")
	}
	return nil
}
func check(r io.Reader, limit int64) error {
	data, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return err
	}
	if int64(len(data)) > limit {
		return fmt.Errorf("JSON bytes exceed bound")
	}
	if !utf8.Valid(data) {
		return fmt.Errorf("invalid UTF-8 JSON bytes")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	count := 0
	if err := value(d, 0, &count, ""); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return fmt.Errorf("trailing JSON content")
	}
	return nil
}
func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: wootc-json-check max-bytes")
		os.Exit(2)
	}
	limit, err := strconv.ParseInt(os.Args[1], 10, 64)
	if err != nil || limit < 1 || limit > 16777216 {
		fmt.Fprintln(os.Stderr, "invalid JSON bound")
		os.Exit(2)
	}
	if err := check(os.Stdin, limit); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
