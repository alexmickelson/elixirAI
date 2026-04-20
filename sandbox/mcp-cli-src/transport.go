package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// ── JSON-RPC message types ──────────────────────────────────────────────────

// RPCRequest is a JSON-RPC 2.0 request or notification.
// Notifications omit the ID field.
type RPCRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id,omitempty"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

// RPCError represents a JSON-RPC 2.0 error object.
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// RPCResponse is a JSON-RPC 2.0 response.
type RPCResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

// ── HTTP transport ──────────────────────────────────────────────────────────

// sendHTTPRequest performs a single JSON-RPC HTTP POST to the given MCP server.
// It handles both plain JSON and SSE (text/event-stream) response formats.
// The sessionID is included as a header when non-empty, and a new session ID
// from the response is returned alongside the parsed RPC response.
func sendHTTPRequest(
	client *http.Client,
	server *ServerConfig,
	sessionID string,
	request RPCRequest,
) (*RPCResponse, string, error) {
	requestBody, err := json.Marshal(request)
	if err != nil {
		return nil, sessionID, fmt.Errorf("marshal request: %w", err)
	}

	httpRequest, err := http.NewRequest("POST", server.URL, bytes.NewReader(requestBody))
	if err != nil {
		return nil, sessionID, fmt.Errorf("create request: %w", err)
	}

	httpRequest.Header.Set("Content-Type", "application/json")
	httpRequest.Header.Set("Accept", "application/json, text/event-stream")
	if sessionID != "" {
		httpRequest.Header.Set("Mcp-Session-Id", sessionID)
	}
	for headerName, headerValue := range server.Headers {
		httpRequest.Header.Set(headerName, headerValue)
	}

	httpResponse, err := client.Do(httpRequest)
	if err != nil {
		return nil, sessionID, fmt.Errorf("connection failed: %w", err)
	}
	defer httpResponse.Body.Close()

	// Capture session ID from response headers
	if newSessionID := httpResponse.Header.Get("Mcp-Session-Id"); newSessionID != "" {
		sessionID = newSessionID
	}

	// 202 Accepted — notification acknowledged, no body expected
	if httpResponse.StatusCode == 202 {
		return nil, sessionID, nil
	}

	if httpResponse.StatusCode != 200 {
		errorBody, _ := io.ReadAll(httpResponse.Body)
		return nil, sessionID, fmt.Errorf("HTTP %d: %s", httpResponse.StatusCode, string(errorBody))
	}

	contentType := httpResponse.Header.Get("Content-Type")

	// SSE response — extract the last JSON-RPC response that has an id
	if strings.Contains(contentType, "text/event-stream") {
		rpcResponse, err := parseSSEStream(httpResponse.Body)
		return rpcResponse, sessionID, err
	}

	// Plain JSON response
	var rpcResponse RPCResponse
	if err := json.NewDecoder(httpResponse.Body).Decode(&rpcResponse); err != nil {
		return nil, sessionID, fmt.Errorf("invalid JSON response: %w", err)
	}
	return &rpcResponse, sessionID, nil
}

// parseSSEStream reads a Server-Sent Events stream and extracts the last
// JSON-RPC response that contains an ID field (ignoring notifications).
func parseSSEStream(reader io.Reader) (*RPCResponse, error) {
	scanner := bufio.NewScanner(reader)
	var lastResponse *RPCResponse

	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		jsonData := strings.TrimPrefix(line, "data: ")
		var rpcResponse RPCResponse
		if json.Unmarshal([]byte(jsonData), &rpcResponse) == nil && rpcResponse.ID != nil {
			lastResponse = &rpcResponse
		}
	}

	if lastResponse == nil {
		return nil, fmt.Errorf("no JSON-RPC response found in SSE stream")
	}
	return lastResponse, nil
}
