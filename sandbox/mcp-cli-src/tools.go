package main

import "encoding/json"

// ToolDefinition represents a tool as returned by the MCP tools/list method.
type ToolDefinition struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
}

// ToolInputSchema is the parsed JSON Schema for a tool's input parameters.
type ToolInputSchema struct {
	Type       string                        `json:"type"`
	Properties map[string]ToolPropertySchema `json:"properties"`
	Required   []string                      `json:"required"`
}

// ToolPropertySchema describes a single property in a tool's input schema.
type ToolPropertySchema struct {
	Type        string   `json:"type"`
	Description string   `json:"description"`
	Enum        []string `json:"enum,omitempty"`
}

// ParseInputSchema deserializes the raw InputSchema JSON into a structured form.
// Returns nil if the schema cannot be parsed.
func (tool *ToolDefinition) ParseInputSchema() *ToolInputSchema {
	var schema ToolInputSchema
	if json.Unmarshal(tool.InputSchema, &schema) != nil {
		return nil
	}
	return &schema
}
