package main

import (
	"fmt"
	"os"
)

func usage() {
	fmt.Print(`mcp-cli — MCP tool client for the sandbox

Usage:
  mcp-cli list                                  List servers + example commands
  mcp-cli tools [SERVER]                        List available tools (with params)
  mcp-cli tools SERVER TOOL [key=value ...]     Call a tool
  mcp-cli schema SERVER TOOL                    Show a tool's input schema (JSON)

Examples:
  mcp-cli list
  mcp-cli tools
  mcp-cli tools mcp-searxng
  mcp-cli tools mcp-searxng searxng_web_search query="elixir genserver"
  mcp-cli schema mcp-searxng searxng_web_search

Config: /etc/mcp/servers.json (override with MCP_CONFIG env var)
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
		runListServers(config)

	case "tools":
		switch {
		case len(os.Args) == 2:
			runListAllTools(config)
		case len(os.Args) == 3:
			runListTools(config, os.Args[2])
		default:
			runCallTool(config, os.Args[2], os.Args[3], os.Args[4:])
		}

	case "schema":
		if len(os.Args) < 4 {
			usage()
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
