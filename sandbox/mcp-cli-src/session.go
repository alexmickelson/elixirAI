package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
)

// Session manages an MCP connection lifecycle with a single server.
// Each Session performs its own initialize handshake and maintains
// the session ID for subsequent requests.
type Session struct {
	server    *ServerConfig
	sessionID string
	client    *http.Client
	requestID int
}

// NewSession creates a new MCP session for the given server.
func NewSession(server *ServerConfig) *Session {
	return &Session{
		server: server,
		client: &http.Client{},
	}
}

func (session *Session) nextRequestID() int {
	session.requestID++
	return session.requestID
}

// send dispatches a JSON-RPC request through the HTTP transport layer
// and updates the session ID from the response.
func (session *Session) send(request RPCRequest) (*RPCResponse, error) {
	response, updatedSessionID, err := sendHTTPRequest(
		session.client, session.server, session.sessionID, request,
	)
	session.sessionID = updatedSessionID
	return response, err
}

// Initialize performs the MCP protocol handshake:
//  1. Sends "initialize" with client capabilities
//  2. Sends "notifications/initialized" to confirm
func (session *Session) Initialize() error {
	response, err := session.send(RPCRequest{
		JSONRPC: "2.0",
		ID:      session.nextRequestID(),
		Method:  "initialize",
		Params: map[string]interface{}{
			"protocolVersion": "2025-03-26",
			"capabilities":    map[string]interface{}{},
			"clientInfo": map[string]string{
				"name":    "mcp-cli",
				"version": "1.0.0",
			},
		},
	})
	if err != nil {
		return fmt.Errorf("initialize: %w", err)
	}
	if response != nil && response.Error != nil {
		return fmt.Errorf("initialize: %s", response.Error.Message)
	}

	// Send the required "initialized" notification (no ID = notification)
	_, _ = session.send(RPCRequest{
		JSONRPC: "2.0",
		Method:  "notifications/initialized",
		Params:  map[string]interface{}{},
	})
	return nil
}

// ListTools fetches the list of available tools from the server.
func (session *Session) ListTools() ([]ToolDefinition, error) {
	response, err := session.send(RPCRequest{
		JSONRPC: "2.0",
		ID:      session.nextRequestID(),
		Method:  "tools/list",
		Params:  map[string]interface{}{},
	})
	if err != nil {
		return nil, err
	}
	if response.Error != nil {
		return nil, fmt.Errorf("tools/list: %s", response.Error.Message)
	}

	var toolsResult struct {
		Tools []ToolDefinition `json:"tools"`
	}
	if err := json.Unmarshal(response.Result, &toolsResult); err != nil {
		return nil, fmt.Errorf("tools/list parse: %w", err)
	}
	return toolsResult.Tools, nil
}

// CallTool invokes a tool by name with the given arguments and returns
// the text content from the response.
func (session *Session) CallTool(toolName string, arguments map[string]interface{}) (string, error) {
	response, err := session.send(RPCRequest{
		JSONRPC: "2.0",
		ID:      session.nextRequestID(),
		Method:  "tools/call",
		Params: map[string]interface{}{
			"name":      toolName,
			"arguments": arguments,
		},
	})
	if err != nil {
		return "", err
	}
	if response.Error != nil {
		return "", fmt.Errorf("tool error: %s", response.Error.Message)
	}

	var callResult struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
		IsError bool `json:"isError"`
	}
	if err := json.Unmarshal(response.Result, &callResult); err != nil {
		// If we can't parse the structured content, return raw result
		return string(response.Result), nil
	}

	var textParts []string
	for _, contentBlock := range callResult.Content {
		if contentBlock.Type == "text" {
			textParts = append(textParts, contentBlock.Text)
		} else {
			textParts = append(textParts, fmt.Sprintf("[%s content]", contentBlock.Type))
		}
	}
	output := strings.Join(textParts, "\n")

	if callResult.IsError {
		return "", fmt.Errorf("%s", output)
	}
	return output, nil
}
