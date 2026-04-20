# Plan: Remove MCP from the Elixir Harness

## Context

MCP tool access has been moved into the sandbox container via a self-contained
Go CLI (`mcp-cli`) that speaks MCP Streamable HTTP directly. The Elixir harness
no longer needs its own MCP client infrastructure.

## What's Being Removed

The Elixir app currently has a full MCP client stack:
- Connects to MCP servers via `Anubis.Client` (streamable HTTP transport)
- Discovers tools at startup, caches them in ETS
- Presents MCP tools as first-class tool calls alongside built-in tools
- Web UI for managing MCP server connections
- Database table for persisting MCP server configs

All of this is being removed. MCP is now exclusively accessed from inside the
sandbox via `mcp-cli`.

## Features Lost by Removal

1. **Native structured tool calling** — MCP tools currently appear as typed tool
   calls (e.g. `mcp:mcp-searxng:searxng_web_search`). After removal, the LLM
   uses `run("mcp-cli tools <server> <tool> key=value")` instead.
2. **Per-conversation tool gating** — Individual MCP tools can be enabled/disabled
   per conversation via `allowed_tools`. After removal, any conversation with
   `run` access can use all MCP tools.
3. **Web UI management** — Admin UI for add/remove/test MCP servers goes away.
   Configuration is now a JSON file in the sandbox.
4. **Automatic tool discovery** — Tools were discovered at startup and presented
   with full schemas. Now the LLM must run `mcp-cli tools` to discover them.
5. **Connection monitoring** — The GenServer retried failed connections and
   reported status. The CLI makes fresh connections per invocation.

## Files to DELETE (5 files)

| File                                                          | Contents                                                                  |
| ------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `lib/elixir_ai/mcp/mcp_server_manager.ex`                     | GenServer: MCP client lifecycle, ETS tool cache, Anubis.Client management |
| `lib/elixir_ai/mcp/mcp_tool_adapter.ex`                       | Converts MCP tool schemas to chat format, dispatches tool calls           |
| `lib/elixir_ai/data/mcp_server.ex`                            | CRUD for `mcp_servers` DB table, YAML→DB sync                             |
| `lib/elixir_ai_web/features/home/mcp_servers_live.ex`         | LiveView component: MCP server management UI (list, test, toggle, delete) |
| `lib/elixir_ai_web/features/home/new_mcp_server_form_live.ex` | LiveView form for adding new MCP servers                                  |

## Files to EDIT (6 Elixir files)

### `lib/elixir_ai/application.ex`
Remove from the supervisor children list:
- `{Registry, keys: :unique, name: ElixirAi.McpRegistry}`
- `{DynamicSupervisor, name: ElixirAi.Mcp.McpClientSupervisor, strategy: :one_for_one}`
- `mcp_server_manager_child_spec()` entry

Remove the `mcp_server_manager_child_spec/0` private function definition.

### `lib/elixir_ai/chat_conversation/ai_tools/ai_tools.ex`
- Remove `build_mcp_tools/2` function
- Remove MCP call from `all_tool_names/0` — currently appends `McpToolAdapter.all_mcp_tool_names()`
- Remove MCP call from `build/2` — currently includes `build_mcp_tools(server, allowed_names)`

### `lib/elixir_ai/data/ai_provider.ex`
- Remove the call to `ElixirAi.McpServer.ensure_mcp_servers_from_file()` (in the startup/init path)

### `lib/elixir_ai/pubsub_topics.ex`
- Remove `def mcp_topic, do: "mcp_servers"` function

### `lib/elixir_ai_web/features/home/home_live.ex`
- Remove `alias ElixirAi.McpServer` (or equivalent)
- Remove PubSub subscription to MCP topic in `mount/3`
- Remove `mcp_servers` assign
- Remove `<.live_component module={McpServersLive} ...>` from the template
- Remove MCP-related event handlers (`handle_info` clauses for MCP events)

### `lib/elixir_ai_web/features/chat/chat_tools_live.ex`
- Remove MCP-specific tool grouping logic in `group_tools/1`
- Remove `mcp:` prefix handling in `display_tool_name/1`
- Simplify to only handle built-in tool names

## Config/Infra to EDIT (4 files)

### `mix.exs`
- Remove `{:anubis_mcp, "~> 1.1"}` from deps

### `providers.yml`
- Remove the `mcp_servers:` section entirely (lines defining mcp-searxng, etc.)
- Keep the `providers:` section unchanged

### `postgres/schema/schema.sql`
- Remove the `mcp_servers` table definition (CREATE TABLE block)

### `docker-compose.yml`
- Keep the `mcp-searxng` service — the sandbox connects to it directly
- Keep `llm_sandbox` volume mount for `mcp-servers.json`
- No changes needed here

## Post-Removal Steps

```bash
# Remove the Elixir dependency
mix deps.unlock anubis_mcp
mix deps.clean anubis_mcp

# Optionally drop the DB table (or just leave it)
# psql: DROP TABLE IF EXISTS mcp_servers;

# Verify compilation
mix compile

# Run tests
mix test
```

## What Stays

- `sandbox/mcp-cli-src/` — Go source for the CLI
- `sandbox/mcp-servers.json` — MCP server config for the sandbox
- `sandbox/Dockerfile` — builds mcp-cli, installs it in the image
- `docker-compose.yml` `mcp-searxng` service — still runs, sandbox connects to it
- The `run` tool description in `ai_tools.ex` mentioning `mcp-cli`
