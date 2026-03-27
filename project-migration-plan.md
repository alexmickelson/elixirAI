# Umbrella Migration Plan: 3 Projects

## Goal

Convert the flat `elixir_ai` project into an Elixir umbrella with 3 apps:

| App                      | Module Prefix         | Has Web?      | Purpose                                                                          |
| ------------------------ | --------------------- | ------------- | -------------------------------------------------------------------------------- |
| `elixir_ai`              | `ElixirAi`            | No            | Shared domain: Ecto schemas, ChatRunner, AiTools, PubSub, PG modules, clustering |
| `elixir_ai_web`          | `ElixirAiWeb`         | Yes (Phoenix) | LiveView UI, controllers, assets                                                 |
| `elixir_ai_command_tool` | `ElixirAiCommandTool` | Yes (Bandit)  | Standalone HTTP command runner, Docker container                                 |

## Dependency Graph

```
elixir_ai_command_tool  (standalone, zero in-umbrella deps)
elixir_ai               (shared core, zero in-umbrella deps)
elixir_ai_web           (depends on :elixir_ai via in_umbrella: true)
```

## Current Structure → Target Structure

```
elixirAI/                          # Umbrella root
├── mix.exs                        # Umbrella mix.exs (apps_path: "apps")
├── config/
│   ├── config.exs                 # Shared base config
│   ├── dev.exs
│   ├── prod.exs
│   ├── test.exs
│   └── runtime.exs
├── docker-compose.yml
├── apps/
│   ├── elixir_ai/                 # Shared core (no endpoint)
│   │   ├── mix.exs
│   │   ├── lib/
│   │   │   ├── elixir_ai.ex
│   │   │   └── elixir_ai/
│   │   │       ├── application.ex
│   │   │       ├── repo.ex
│   │   │       ├── ai_provider.ex
│   │   │       ├── conversation.ex
│   │   │       ├── message.ex
│   │   │       ├── data/
│   │   │       ├── chat_runner/
│   │   │       ├── ai_tools/
│   │   │       ├── pubsub_topics.ex
│   │   │       ├── chat_utils.ex
│   │   │       ├── audio_processing.ex
│   │   │       ├── audio_worker.ex
│   │   │       ├── *_pg.ex
│   │   │       ├── cluster_singleton_launcher.ex
│   │   │       ├── conversation_manager.ex
│   │   │       └── tool_testing.ex
│   │   ├── priv/
│   │   │   └── repo/migrations/
│   │   └── test/
│   │
│   ├── elixir_ai_web/             # Phoenix web UI
│   │   ├── mix.exs
│   │   ├── lib/
│   │   │   ├── elixir_ai_web.ex
│   │   │   └── elixir_ai_web/
│   │   │       ├── application.ex  # NEW — owns Telemetry + Endpoint
│   │   │       ├── endpoint.ex
│   │   │       ├── router.ex
│   │   │       ├── telemetry.ex
│   │   │       ├── controllers/
│   │   │       ├── live/
│   │   │       ├── components/
│   │   │       └── plugs/
│   │   ├── assets/                # CSS, JS, vendor
│   │   ├── priv/
│   │   │   ├── static/
│   │   │   └── gettext/
│   │   └── test/
│   │
│   └── elixir_ai_command_tool/    # Standalone command runner
│       ├── mix.exs
│       ├── lib/
│       │   └── elixir_ai_command_tool/
│       │       ├── application.ex
│       │       ├── http/
│       │       │   ├── router.ex
│       │       │   ├── client.ex
│       │       │   └── protocol.ex
│       │       └── runner/
│       │           ├── command_executor.ex
│       │           ├── socket_server.ex
│       │           └── truncator.ex
│       ├── Dockerfile
│       ├── entrypoint.sh
│       ├── shims/
│       └── test/
```

---

## Phase 1: Scaffold Umbrella Root

1. **Replace root `mix.exs`** with umbrella project definition:

```elixir
defmodule ElixirAi.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  defp deps do
    [] # All deps move to individual apps
  end

  defp aliases do
    [
      setup: ["cmd mix deps.get", "cmd mix ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
```

2. **Create `apps/` directory** with three subdirectories: `elixir_ai/`, `elixir_ai_web/`, `elixir_ai_command_tool/`

---

## Phase 2: Create `apps/elixir_ai` (Shared Core)

### 2.1 — `apps/elixir_ai/mix.exs`

```elixir
defmodule ElixirAi.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_ai,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ElixirAi.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ecto_sql, "~> 3.11"},
      {:postgrex, ">= 0.22.0"},
      {:jason, "~> 1.2"},
      {:horde, "~> 0.9"},
      {:libcluster, "~> 3.3"},
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.12"},
      {:zoi, "~> 0.17"},
      {:dotenvy, "~> 1.1.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:mimic, "~> 2.3.0", only: :test}
    ]
  end

  defp aliases do
    [
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"]
    ]
  end
end
```

### 2.2 — Move Files

| Source                            | Destination                           |
| --------------------------------- | ------------------------------------- |
| `lib/elixir_ai.ex`                | `apps/elixir_ai/lib/elixir_ai.ex`     |
| `lib/elixir_ai/` (all contents)   | `apps/elixir_ai/lib/elixir_ai/`       |
| `priv/repo/`                      | `apps/elixir_ai/priv/repo/`           |
| `test/db_helper_test.exs`         | `apps/elixir_ai/test/`                |
| `test/message_storage_test.exs`   | `apps/elixir_ai/test/`                |
| `test/stream_line_utils_test.exs` | `apps/elixir_ai/test/`                |
| `test/support/`                   | `apps/elixir_ai/test/support/`        |
| `test/test_helper.exs`            | `apps/elixir_ai/test/test_helper.exs` |

### 2.3 — Rewrite `apps/elixir_ai/lib/elixir_ai/application.ex`

- **Remove** the `tools_api` branch and `tools_api_children/0` — that's command_tool's concern now
- **Remove** `ElixirAiWeb.Telemetry` and `ElixirAiWeb.Endpoint` from children (those move to web app)
- **Remove** `config_change/3` (moves to web app)
- **Keep** only the core supervision tree:

```elixir
defmodule ElixirAi.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      repo_child_spec(),
      default_provider_task(),
      {Cluster.Supervisor,
       [Application.get_env(:libcluster, :topologies, []),
        [name: ElixirAi.ClusterSupervisor]]},
      {Phoenix.PubSub, name: ElixirAi.PubSub},
      {ElixirAi.LiveViewPG, []},
      {ElixirAi.RunnerPG, []},
      {ElixirAi.SingletonPG, []},
      {ElixirAi.PageToolsPG, []},
      {ElixirAi.AudioProcessingPG, []},
      {DynamicSupervisor,
       name: ElixirAi.AudioWorkerSupervisor, strategy: :one_for_one},
      ElixirAi.ToolTesting,
      {Horde.Registry,
       [name: ElixirAi.ChatRegistry, keys: :unique, members: :auto,
        delta_crdt_options: [sync_interval: 100]]},
      {Horde.DynamicSupervisor,
       [name: ElixirAi.ChatRunnerSupervisor, strategy: :one_for_one,
        members: :auto, delta_crdt_options: [sync_interval: 100],
        process_redistribution: :active]},
      cluster_singleton_child_spec(ElixirAi.ConversationManager)
    ]

    opts = [strategy: :one_for_one, name: ElixirAi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # ... keep repo_child_spec/0, default_provider_task/0, cluster_singleton_child_spec/1 unchanged
end
```

### 2.4 — Move `Http.Client` Here

The `ElixirAiCommandTool.Http.Client` module is called by the main app (in `AiTools`) to talk to the runner over HTTP. It should live in the shared core, not in the runner container.

- Move `lib/elixir_ai_command_tool/http/client.ex` → `apps/elixir_ai/lib/elixir_ai/command_tool_client.ex`
- Rename module to `ElixirAi.CommandToolClient`
- Update reference in `ElixirAi.AiTools` from `ElixirAiCommandTool.Http.Client` to `ElixirAi.CommandToolClient`

---

## Phase 3: Create `apps/elixir_ai_web` (Phoenix Web)

### 3.1 — `apps/elixir_ai_web/mix.exs`

```elixir
defmodule ElixirAiWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_ai_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ElixirAiWeb.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:elixir_ai, in_umbrella: true},
      {:phoenix, "~> 1.7.21"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.0.0"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.8", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.1.1",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:html_sanitize_ex, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:bandit, "~> 1.5"},
      {:floki, ">= 0.30.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dns_cluster, "~> 0.1.1", only: :dev}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["tailwind elixir_ai", "esbuild elixir_ai"],
      "assets.deploy": [
        "tailwind elixir_ai --minify",
        "esbuild elixir_ai --minify",
        "phx.digest"
      ]
    ]
  end
end
```

### 3.2 — Create `apps/elixir_ai_web/lib/elixir_ai_web/application.ex` (NEW)

```elixir
defmodule ElixirAiWeb.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      ElixirAiWeb.Telemetry,
      ElixirAiWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ElixirAiWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  def config_change(changed, _new, removed) do
    ElixirAiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

### 3.3 — Move Files

| Source                              | Destination                               |
| ----------------------------------- | ----------------------------------------- |
| `lib/elixir_ai_web.ex`              | `apps/elixir_ai_web/lib/elixir_ai_web.ex` |
| `lib/elixir_ai_web/` (all contents) | `apps/elixir_ai_web/lib/elixir_ai_web/`   |
| `assets/`                           | `apps/elixir_ai_web/assets/`              |
| `priv/static/`                      | `apps/elixir_ai_web/priv/static/`         |
| `priv/gettext/`                     | `apps/elixir_ai_web/priv/gettext/`        |
| `test/elixir_ai_web/`               | `apps/elixir_ai_web/test/elixir_ai_web/`  |

---

## Phase 4: Create `apps/elixir_ai_command_tool` (Runner)

### 4.1 — `apps/elixir_ai_command_tool/mix.exs`

```elixir
defmodule ElixirAiCommandTool.MixProject do
  use Mix.Project

  def project do
    [
      app: :elixir_ai_command_tool,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {ElixirAiCommandTool.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.2"},
      {:plug, "~> 1.16"}
    ]
  end
end
```

**Note:** `:req` is NOT a dep here. The `Http.Client` moved to `:elixir_ai` in Phase 2.4. This app has zero in-umbrella dependencies.

### 4.2 — Move Files

| Source                                        | Destination                                                               |
| --------------------------------------------- | ------------------------------------------------------------------------- |
| `lib/elixir_ai_command_tool/application.ex`   | `apps/elixir_ai_command_tool/lib/elixir_ai_command_tool/application.ex`   |
| `lib/elixir_ai_command_tool/http/router.ex`   | `apps/elixir_ai_command_tool/lib/elixir_ai_command_tool/http/router.ex`   |
| `lib/elixir_ai_command_tool/http/protocol.ex` | `apps/elixir_ai_command_tool/lib/elixir_ai_command_tool/http/protocol.ex` |
| `lib/elixir_ai_command_tool/runner/`          | `apps/elixir_ai_command_tool/lib/elixir_ai_command_tool/runner/`          |
| `lib/elixir_ai_command_tool/Dockerfile`       | `apps/elixir_ai_command_tool/Dockerfile`                                  |
| `lib/elixir_ai_command_tool/entrypoint.sh`    | `apps/elixir_ai_command_tool/entrypoint.sh`                               |
| `lib/elixir_ai_command_tool/shims/`           | `apps/elixir_ai_command_tool/shims/`                                      |

**Do NOT move** `lib/elixir_ai_command_tool/http/client.ex` — it moved to `:elixir_ai` in Phase 2.4.

### 4.3 — Revert Application to `use Application`

Since it's now its own OTP app with `mod:` in mix.exs, it needs `start/2` (not `start_link/1`):

```elixir
defmodule ElixirAiCommandTool.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    port = Application.get_env(:elixir_ai_command_tool, :port, 4001)

    children = [
      {Bandit, plug: ElixirAiCommandTool.Http.Router, port: port},
      {ElixirAiCommandTool.Runner.SocketServer, []}
    ]

    opts = [strategy: :one_for_one, name: ElixirAiCommandTool.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### 4.4 — Delete Orphaned Files

- `lib/elixir_ai_command_tool/config/config.exs` — superseded by umbrella config
- `lib/elixir_ai_command_tool/config/runtime.exs` — superseded by umbrella config

---

## Phase 5: Update Config

### 5.1 — `config/config.exs`

Split config blocks per app. Key changes:

- `:elixir_ai` — Repo, generators, PubSub
- `:elixir_ai_web` — Endpoint, esbuild, tailwind
- `:elixir_ai_command_tool` — port config
- Remove all `tools_api` references

### 5.2 — `config/dev.exs`

Update Endpoint references to use `:elixir_ai_web` app:

```elixir
config :elixir_ai_web, ElixirAiWeb.Endpoint, ...
```

### 5.3 — `config/prod.exs`

Update Endpoint references to use `:elixir_ai_web` app.

### 5.4 — `config/runtime.exs`

- **Remove** `tools_api` env branching entirely
- `:elixir_ai` gets AI endpoint, token, DB config
- `:elixir_ai_web` gets secret key, host, port
- `:elixir_ai_command_tool` reads `COMMAND_TOOL_PORT`

### 5.5 — Delete `config/tools_api.exs`

No longer needed — command_tool is its own OTP app.

---

## Phase 6: Update Docker

### 6.1 — `apps/elixir_ai_command_tool/Dockerfile`

- Build context must be the umbrella root (`.`), not the app directory
- Build with `MIX_ENV=prod` (not `tools_api`)
- Use `mix release elixir_ai_command_tool` or `mix run --app elixir_ai_command_tool`
- Only the `:elixir_ai_command_tool` app will start — no Phoenix, no Ecto

### 6.2 — `docker-compose.yml`

```yaml
command_runner:
  build:
    context: .
    dockerfile: apps/elixir_ai_command_tool/Dockerfile
  environment:
    - MIX_ENV=prod           # was tools_api
    - COMMAND_TOOL_PORT=4001
```

### 6.3 — Main App `Dockerfile`

Update to build the umbrella and release `:elixir_ai_web` (which pulls in `:elixir_ai` as a dep automatically).

---

## Phase 7: Cleanup & Verify

1. Delete the old flat `lib/` directory (empty after all moves)
2. Delete old root `mix.exs` (replaced by umbrella version)
3. Delete `config/tools_api.exs`
4. Delete `lib/elixir_ai_command_tool/config/` (orphaned)
5. Run from umbrella root:

```bash
mix deps.get
mix compile
mix test
```

6. Build and verify Docker:

```bash
docker compose build
docker compose up
```

---

## Key Decisions & Gotchas

| Topic                    | Decision                                                                                                 | Rationale                                                                                                |
| ------------------------ | -------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **Client module**        | Lives in `:elixir_ai`, not `:elixir_ai_command_tool`                                                     | Called by AiTools in the main app to talk to runner over HTTP. Runner should have zero in-umbrella deps. |
| **PubSub**               | Started in `ElixirAi.Application`                                                                        | Web app accesses it via `{:elixir_ai, in_umbrella: true}`                                                |
| **Horde + Clustering**   | Stays in `:elixir_ai`                                                                                    | Core domain concern, not web-specific                                                                    |
| **Telemetry + Endpoint** | Moves to `ElixirAiWeb.Application`                                                                       | Web-specific supervision                                                                                 |
| **Asset paths**          | esbuild/tailwind config must update to `apps/elixir_ai_web/assets/`                                      | Paths change relative to umbrella root                                                                   |
| **`elixirc_paths`**      | Each app manages its own                                                                                 | Test support files go to the app that owns them                                                          |
| **No circular deps**     | `:elixir_ai_command_tool` → nothing, `:elixir_ai` → nothing in-umbrella, `:elixir_ai_web` → `:elixir_ai` | Clean one-way dependency graph                                                                           |
| **`tools_api` MIX_ENV**  | Deleted                                                                                                  | No longer needed — command_tool is its own app with its own `mod:`                                       |