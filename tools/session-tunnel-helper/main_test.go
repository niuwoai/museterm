package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func TestParseArguments(t *testing.T) {
	tests := []struct {
		name        string
		arguments   []string
		wantAddress string
		wantToken   string
		wantError   bool
	}{
		{name: "IPv4", arguments: []string{"127.0.0.1", "3306", "abc123"}, wantAddress: "127.0.0.1:3306", wantToken: "abc123"},
		{name: "IPv6", arguments: []string{"fd00::12", "5432", "token"}, wantAddress: "[fd00::12]:5432", wantToken: "token"},
		{name: "invalid port", arguments: []string{"db", "0", "token"}, wantError: true},
		{name: "invalid token", arguments: []string{"db", "3306", "not-valid"}, wantError: true},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			address, token, err := parseArguments(test.arguments)
			if test.wantError {
				if err == nil {
					t.Fatal("expected an error")
				}
				return
			}
			if err != nil {
				t.Fatalf("parse arguments: %v", err)
			}
			if address != test.wantAddress || token != test.wantToken {
				t.Fatalf("got (%q, %q), want (%q, %q)", address, token, test.wantAddress, test.wantToken)
			}
		})
	}
}

func TestHelperReadyAndStopped(t *testing.T) {
	token := "testtoken"
	input := bytes.NewBuffer(nil)
	encoder := json.NewEncoder(input)
	if err := encoder.Encode(frame{Version: protocolVersion, Token: token, Type: "shutdown"}); err != nil {
		t.Fatalf("encode shutdown: %v", err)
	}
	output := bytes.NewBuffer(nil)

	if err := newHelper("127.0.0.1:9", token, output).run(input); err != nil {
		t.Fatalf("run helper: %v", err)
	}

	decoder := json.NewDecoder(output)
	var messages []frame
	for {
		var message frame
		if err := decoder.Decode(&message); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			t.Fatalf("decode output: %v", err)
		}
		messages = append(messages, message)
	}
	if len(messages) != 2 || messages[0].Type != "ready" || messages[1].Type != "stopped" {
		t.Fatalf("unexpected messages: %#v", messages)
	}
}

func TestHelperForwardsTCP(t *testing.T) {
	targetClient, targetServer := net.Pipe()
	defer targetClient.Close()
	defer targetServer.Close()
	go func() {
		buffer := make([]byte, 64)
		count, readErr := targetServer.Read(buffer)
		if readErr == nil {
			_, _ = targetServer.Write(buffer[:count])
		}
	}()

	token := "forwardtoken"
	clientInput, helperInput := net.Pipe()
	helperOutput, clientOutput := net.Pipe()
	defer clientInput.Close()
	defer clientOutput.Close()
	helper := newHelper("target.internal:3306", token, helperOutput)
	helper.dial = func(network, address string, timeout time.Duration) (net.Conn, error) {
		if network != "tcp" || address != "target.internal:3306" || timeout != dialTimeout {
			t.Fatalf("unexpected dial: %s %s %s", network, address, timeout)
		}
		return targetClient, nil
	}
	done := make(chan error, 1)
	go func() {
		done <- helper.run(helperInput)
		_ = helperInput.Close()
		_ = helperOutput.Close()
	}()

	decoder := json.NewDecoder(clientOutput)
	encoder := json.NewEncoder(clientInput)
	var message frame
	if err := decoder.Decode(&message); err != nil || message.Type != "ready" {
		t.Fatalf("ready frame: %#v, %v", message, err)
	}
	channel := uint32(7)
	if err := encoder.Encode(frame{Version: protocolVersion, Token: token, Type: "open", Channel: &channel}); err != nil {
		t.Fatalf("open frame: %v", err)
	}
	if err := decoder.Decode(&message); err != nil || message.Type != "opened" {
		t.Fatalf("opened frame: %#v, %v", message, err)
	}
	payload := []byte("hello-through-helper")
	if err := encoder.Encode(frame{Version: protocolVersion, Token: token, Type: "data", Channel: &channel, Data: "aGVsbG8tdGhyb3VnaC1oZWxwZXI="}); err != nil {
		t.Fatalf("data frame: %v", err)
	}
	if err := decoder.Decode(&message); err != nil || message.Type != "data" {
		t.Fatalf("response frame: %#v, %v", message, err)
	}
	decoded, err := base64Decode(message.Data)
	if err != nil || !bytes.Equal(decoded, payload) {
		t.Fatalf("decoded payload %q, error %v", decoded, err)
	}
	if err := encoder.Encode(frame{Version: protocolVersion, Token: token, Type: "shutdown"}); err != nil {
		t.Fatalf("shutdown frame: %v", err)
	}
	for message.Type != "stopped" {
		if err := decoder.Decode(&message); err != nil {
			t.Fatalf("stopped frame: %v", err)
		}
	}
	if err := <-done; err != nil {
		t.Fatalf("helper stopped: %v", err)
	}
}

func base64Decode(value string) ([]byte, error) {
	return base64.StdEncoding.DecodeString(value)
}
