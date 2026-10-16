package main

import (
	"context"
	"io"
	"strings"
	"testing"
	"time"
)

func TestQMPRejectsMissingGreetingPromptly(t *testing.T) {
	input, output := io.Pipe()
	defer input.Close()
	defer output.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	_, err := connectQMP(ctx, output, strings.NewReader("{\"return\":{}}\n"))
	if err == nil || ctx.Err() != nil {
		t.Fatalf("bad greeting did not fail promptly: %v", err)
	}
}
