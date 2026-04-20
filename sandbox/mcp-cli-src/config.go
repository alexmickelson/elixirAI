package main

import (
	"encoding/json"
	"fmt"
	"os"
)

const defaultConfigPath = "/etc/mcp/servers.json"

// ServerConfig holds connection details for a single MCP server.
type ServerConfig struct {
	Name    string            `json:"name"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
}

// Config is the top-level configuration containing all MCP server definitions.
type Config struct {
	Servers []ServerConfig `json:"servers"`
}

// loadConfig reads and parses the MCP server configuration file.
// The path defaults to /etc/mcp/servers.json but can be overridden
// with the MCP_CONFIG environment variable.
func loadConfig() (*Config, error) {
	configPath := os.Getenv("MCP_CONFIG")
	if configPath == "" {
		configPath = defaultConfigPath
	}

	data, err := os.ReadFile(configPath)
	if err != nil {
		return nil, fmt.Errorf("config not found: %s", configPath)
	}

	var config Config
	if err := json.Unmarshal(data, &config); err != nil {
		return nil, fmt.Errorf("invalid JSON in %s: %w", configPath, err)
	}
	return &config, nil
}

// FindServer looks up a server by name, returning an error if not found.
func (config *Config) FindServer(name string) (*ServerConfig, error) {
	for idx := range config.Servers {
		if config.Servers[idx].Name == name {
			return &config.Servers[idx], nil
		}
	}
	return nil, fmt.Errorf("unknown server: %s", name)
}
