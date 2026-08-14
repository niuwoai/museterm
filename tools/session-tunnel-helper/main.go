package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	protocolVersion = 1
	dataChunkBytes  = 12 * 1024
	dialTimeout     = 10 * time.Second
)

type frame struct {
	Version int     `json:"v"`
	Token   string  `json:"token"`
	Type    string  `json:"type"`
	Channel *uint32 `json:"channel,omitempty"`
	Data    string  `json:"data,omitempty"`
	Message string  `json:"message,omitempty"`
}

type helper struct {
	targetAddress string
	token         string
	dial          func(string, string, time.Duration) (net.Conn, error)
	encoder       *json.Encoder
	writeMu       sync.Mutex
	clientsMu     sync.Mutex
	clients       map[uint32]net.Conn
	pendingWrites map[uint32][][]byte
	pumps         sync.WaitGroup
	stopping      atomic.Bool
}

func newHelper(targetAddress, token string, output io.Writer) *helper {
	return &helper{
		targetAddress: targetAddress,
		token:         token,
		dial:          net.DialTimeout,
		encoder:       json.NewEncoder(output),
		clients:       make(map[uint32]net.Conn),
		pendingWrites: make(map[uint32][][]byte),
	}
}

func (h *helper) run(input io.Reader) error {
	if err := h.emit(frame{Type: "ready"}); err != nil {
		return fmt.Errorf("emit ready frame: %w", err)
	}

	decoder := json.NewDecoder(bufio.NewReader(input))
	for {
		var message frame
		if err := decoder.Decode(&message); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return fmt.Errorf("decode input frame: %w", err)
		}
		if message.Version != protocolVersion || message.Token != h.token {
			continue
		}
		if message.Type == "shutdown" {
			break
		}
		h.handle(message)
	}

	h.stopping.Store(true)
	h.closeAll()
	h.pumps.Wait()
	if err := h.emit(frame{Type: "stopped"}); err != nil {
		return fmt.Errorf("emit stopped frame: %w", err)
	}
	return nil
}

func (h *helper) handle(message frame) {
	switch message.Type {
	case "open":
		if message.Channel != nil {
			h.open(*message.Channel)
		}
	case "data":
		if message.Channel != nil {
			h.write(*message.Channel, message.Data)
		}
	case "close":
		if message.Channel != nil {
			h.close(*message.Channel, false)
		}
	case "ping":
		_ = h.emit(frame{Type: "pong"})
	}
}

func (h *helper) open(channel uint32) {
	if h.stopping.Load() {
		return
	}
	h.pumps.Add(1)
	go func() {
		defer h.pumps.Done()
		connection, err := h.dial("tcp", h.targetAddress, dialTimeout)
		if err != nil {
			_ = h.emit(frame{Type: "open_failed", Channel: &channel})
			return
		}
		if tcpConnection, ok := connection.(*net.TCPConn); ok {
			_ = tcpConnection.SetNoDelay(true)
		}
		pending, stored := h.store(channel, connection)
		if h.stopping.Load() || !stored {
			_ = connection.Close()
			return
		}
		if err := h.emit(frame{Type: "opened", Channel: &channel}); err != nil {
			h.close(channel, false)
			return
		}
		for _, payload := range pending {
			if !h.writePayload(channel, connection, payload) {
				return
			}
		}
		h.pumpRemote(channel, connection)
	}()
}

func (h *helper) store(channel uint32, connection net.Conn) ([][]byte, bool) {
	h.clientsMu.Lock()
	defer h.clientsMu.Unlock()
	if _, exists := h.clients[channel]; exists {
		return nil, false
	}
	h.clients[channel] = connection
	pending := h.pendingWrites[channel]
	delete(h.pendingWrites, channel)
	return pending, true
}

func (h *helper) pumpRemote(channel uint32, connection net.Conn) {
	buffer := make([]byte, dataChunkBytes)
	for {
		count, err := connection.Read(buffer)
		if count > 0 {
			encoded := base64.StdEncoding.EncodeToString(buffer[:count])
			if emitErr := h.emit(frame{Type: "data", Channel: &channel, Data: encoded}); emitErr != nil {
				break
			}
		}
		if err != nil {
			break
		}
	}
	h.close(channel, true)
}

func (h *helper) write(channel uint32, encoded string) {
	payload, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil {
		h.close(channel, true)
		return
	}
	connection := h.client(channel)
	if connection == nil {
		h.queuePendingWrite(channel, payload)
		return
	}
	h.writePayload(channel, connection, payload)
}

func (h *helper) queuePendingWrite(channel uint32, payload []byte) {
	h.clientsMu.Lock()
	defer h.clientsMu.Unlock()
	if _, exists := h.clients[channel]; exists {
		return
	}
	h.pendingWrites[channel] = append(h.pendingWrites[channel], payload)
}

func (h *helper) writePayload(channel uint32, connection net.Conn, payload []byte) bool {
	for len(payload) > 0 {
		count, writeErr := connection.Write(payload)
		if writeErr != nil || count == 0 {
			h.close(channel, true)
			return false
		}
		payload = payload[count:]
	}
	return true
}

func (h *helper) client(channel uint32) net.Conn {
	h.clientsMu.Lock()
	defer h.clientsMu.Unlock()
	return h.clients[channel]
}

func (h *helper) close(channel uint32, notify bool) {
	h.clientsMu.Lock()
	connection := h.clients[channel]
	delete(h.clients, channel)
	delete(h.pendingWrites, channel)
	h.clientsMu.Unlock()
	if connection == nil {
		return
	}
	_ = connection.Close()
	if notify && !h.stopping.Load() {
		_ = h.emit(frame{Type: "close", Channel: &channel})
	}
}

func (h *helper) closeAll() {
	h.clientsMu.Lock()
	connections := h.clients
	h.clients = make(map[uint32]net.Conn)
	h.clientsMu.Unlock()
	for _, connection := range connections {
		_ = connection.Close()
	}
}

func (h *helper) emit(message frame) error {
	message.Version = protocolVersion
	message.Token = h.token
	h.writeMu.Lock()
	defer h.writeMu.Unlock()
	return h.encoder.Encode(message)
}

func parseArguments(arguments []string) (string, string, error) {
	if len(arguments) != 3 {
		return "", "", errors.New("expected target host, target port, and session token")
	}
	host := strings.TrimSpace(arguments[0])
	if host == "" {
		return "", "", errors.New("target host is empty")
	}
	port, err := strconv.Atoi(arguments[1])
	if err != nil || port < 1 || port > 65535 {
		return "", "", errors.New("target port is invalid")
	}
	token := arguments[2]
	if token == "" || len(token) > 128 {
		return "", "", errors.New("session token is invalid")
	}
	for _, character := range token {
		if !((character >= 'a' && character <= 'z') ||
			(character >= 'A' && character <= 'Z') ||
			(character >= '0' && character <= '9')) {
			return "", "", errors.New("session token is invalid")
		}
	}
	return net.JoinHostPort(host, strconv.Itoa(port)), token, nil
}

func main() {
	targetAddress, token, err := parseArguments(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := newHelper(targetAddress, token, os.Stdout).run(os.Stdin); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
