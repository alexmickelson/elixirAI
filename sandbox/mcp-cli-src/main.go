package main

import (
	"fmt"
	"os"
)

func usage() {
	fmt.Print(`mcp-cli — MCP tool client for the sandbox

Usage:
	mcp-cli list
	mcp-cli tools [SERVER]
	mcp-cli tools SERVER TOOL [key=value ...]
	mcp-cli schema SERVER TOOL

Examples:
  mcp-cli list
	mcp-cli tools demo
	mcp-cli tools demo search query="elixir"
  mcp-cli schema SERVER TOOL

Use "mcp-cli <command> --help" for more information about a command.

Config: /etc/mcp/servers.json (override with MCP_CONFIG env var)
`)
}

func listHelp() {
	fmt.Print(`mcp-cli list — Show all configured MCP servers

Usage:
  mcp-cli list

Examples:
	mcp-cli list

Config: /etc/mcp/servers.json (override with MCP_CONFIG env var)
`)
}

func toolsHelp() {
	fmt.Print(`mcp-cli tools — List or call MCP tools

Usage:
	mcp-cli tools
	mcp-cli tools SERVER
	mcp-cli tools SERVER TOOL [key=value ...]

Examples:
	mcp-cli tools
	mcp-cli tools demo
	mcp-cli tools demo search query="elixir"
	mcp-cli tools demo search --help

Use "mcp-cli tools SERVER TOOL --help" to see a specific tool's parameters.
`)
}

func toolsCallHelp(serverName string) {
	fmt.Printf(`mcp-cli tools %s <TOOL> — Call a tool on %s

Usage:
  mcp-cli tools %s TOOL [key=value ...]

Examples:
	mcp-cli tools %s TOOL query="search terms"
	mcp-cli tools %s TOOL count=10 verbose=true
	mcp-cli schema %s TOOL
`, serverName, serverName, serverName, serverName, serverName)
}

func schemaHelp() {
	fmt.Print(`mcp-cli schema — Show a tool's input schema as JSON

Usage:
  mcp-cli schema SERVER TOOL

Examples:
	mcp-cli schema demo search
`)
}

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	config, err := loadConfig()
	exitOnError(err)

	switch os.Args[1] {
	case "list":
		if len(os.Args) > 2 && isHelpFlag(os.Args[2]) {
			listHelp()
			return
		}
		runListServers(config)

	case "tools":
		switch {
		case len(os.Args) == 2:
			runListAllTools(config)
		case isHelpFlag(os.Args[2]):
			toolsHelp()
		case len(os.Args) == 3:
			runListTools(config, os.Args[2])
		case isHelpFlag(os.Args[3]):
			toolsCallHelp(os.Args[2])
		default:
			runCallTool(config, os.Args[2], os.Args[3], os.Args[4:])
		}

	case "schema":
		if len(os.Args) > 2 && isHelpFlag(os.Args[2]) {
			schemaHelp()
			return
		}
		if len(os.Args) < 4 {
			schemaHelp()
			os.Exit(1)
		}
		runShowSchema(config, os.Args[2], os.Args[3])

	case "help", "--help", "-h":
		usage()

	default:
		usage()
		os.Exit(1)
	}
}
