package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
)

// runListServers prints all configured servers with example commands.
func runListServers(config *Config) {
	fmt.Println("Configured MCP servers:")
	fmt.Println()
	for _, server := range config.Servers {
		fmt.Printf("  %s\n", server.Name)
		fmt.Printf("    url: %s\n", server.URL)
		fmt.Println("    examples:")
		fmt.Printf("      mcp-cli tools %s\n", server.Name)
		fmt.Printf("      mcp-cli tools %s <tool_name> key=value\n", server.Name)
		fmt.Printf("      mcp-cli schema %s <tool_name>\n", server.Name)
		fmt.Println()
	}
}

// runListAllTools lists available tools from every configured server.
func runListAllTools(config *Config) {
	for _, server := range config.Servers {
		fmt.Printf("── %s ──\n", server.Name)
		runListTools(config, server.Name)
	}
}

// runListTools connects to a single server and prints its available tools
// with descriptions, parameters, and usage examples.
func runListTools(config *Config, serverName string) {
	server, err := config.FindServer(serverName)
	exitOnError(err)

	session := NewSession(server)
	exitOnError(session.Initialize())

	toolDefs, err := session.ListTools()
	exitOnError(err)

	if len(toolDefs) == 0 {
		fmt.Printf("No tools available on %s\n", serverName)
		return
	}

	fmt.Printf("Tools on %s:\n\n", serverName)
	for _, tool := range toolDefs {
		printToolHelp(serverName, tool)
	}
}

// printToolHelp prints a single tool's name, description, parameters, and usage.
func printToolHelp(serverName string, tool ToolDefinition) {
	description := tool.Description
	if newlineIdx := strings.Index(description, "\n"); newlineIdx >= 0 {
		description = description[:newlineIdx]
	}
	if description == "" {
		description = "(no description)"
	}

	fmt.Printf("  %s\n", tool.Name)
	fmt.Printf("    %s\n", description)

	schema := tool.ParseInputSchema()
	if schema != nil && len(schema.Properties) > 0 {
		requiredSet := make(map[string]bool)
		for _, requiredName := range schema.Required {
			requiredSet[requiredName] = true
		}

		fmt.Printf("    params:\n")
		for paramName, paramSchema := range schema.Properties {
			requiredLabel := ""
			if requiredSet[paramName] {
				requiredLabel = " (required)"
			}

			paramDescription := paramSchema.Description
			if newlineIdx := strings.Index(paramDescription, "\n"); newlineIdx >= 0 {
				paramDescription = paramDescription[:newlineIdx]
			}

			if paramDescription != "" {
				fmt.Printf("      %s: %s — %s%s\n", paramName, paramSchema.Type, paramDescription, requiredLabel)
			} else {
				fmt.Printf("      %s: %s%s\n", paramName, paramSchema.Type, requiredLabel)
			}

			if len(paramSchema.Enum) > 0 {
				fmt.Printf("        values: %s\n", strings.Join(paramSchema.Enum, ", "))
			}
		}
	}

	// Print usage example with required params as placeholders
	fmt.Printf("    usage: mcp-cli tools %s %s", serverName, tool.Name)
	if schema != nil {
		for _, requiredParam := range schema.Required {
			fmt.Printf(" %s=<value>", requiredParam)
		}
	}
	fmt.Println()
	fmt.Println()
}

// runCallTool connects to a server, invokes the named tool, and prints the result.
func runCallTool(config *Config, serverName, toolName string, rawArgs []string) {
	server, err := config.FindServer(serverName)
	exitOnError(err)

	arguments := parseKeyValueArgs(rawArgs)

	session := NewSession(server)
	exitOnError(session.Initialize())

	result, err := session.CallTool(toolName, arguments)
	exitOnError(err)

	fmt.Println(result)
}

// runShowSchema connects to a server, finds the named tool, and prints
// its input schema as formatted JSON.
func runShowSchema(config *Config, serverName, toolName string) {
	server, err := config.FindServer(serverName)
	exitOnError(err)

	session := NewSession(server)
	exitOnError(session.Initialize())

	toolDefs, err := session.ListTools()
	exitOnError(err)

	for _, tool := range toolDefs {
		if tool.Name == toolName {
			var prettyJSON bytes.Buffer
			if json.Indent(&prettyJSON, tool.InputSchema, "", "  ") == nil {
				fmt.Println(prettyJSON.String())
			} else {
				fmt.Println(string(tool.InputSchema))
			}
			return
		}
	}
	exitWithError("tool not found: %s (on server %s)", toolName, serverName)
}
