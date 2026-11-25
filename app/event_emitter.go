package main

import (
	"encoding/json"
)

// EventEmitter defines the interface for emitting progress events to the frontend or shell.
type EventEmitter interface {
	Emit(event string, data any)
}

// stdioEmitter formats events as JSON-RPC 2.0 notifications and writes them to an output stream.
type stdioEmitter struct {
	writer *synchronizedWriter
}

func newStdioEmitter(w *synchronizedWriter) *stdioEmitter {
	return &stdioEmitter{writer: w}
}

func (s *stdioEmitter) Emit(event string, data any) {
	notif := jsonrpcNotification{
		JSONRPC: "2.0",
		Method:  event,
		Params:  data,
	}
	payload, err := json.Marshal(notif)
	if err != nil {
		return
	}
	_ = s.writer.WriteLine(payload)
}
