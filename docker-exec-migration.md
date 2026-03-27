# Migration: Unix-Style CLI Agent with `docker exec`

## Philosophy

Based on the *nix Agent pattern: LLMs are terminal operators. They already
speak CLI fluently from training data. Instead of a catalog of typed function
calls, expose **one `run` tool** and let the LLM compose Unix pipelines.

**Core principles:**
1. **Single tool** — one `run(command="...")` replaces multiple typed tools
2. **Pipes work natively** — `bash -c` gives `|`, `&&`, `||`, `;` for free
3. **Progressive discovery** — `--help` at three levels, not docs in system prompt
4. **Error messages navigate** — every error says what to do instead
5. **Consistent output format** — metadata footer on every result (`[exit:N | Xms]`)
6. **Two-layer architecture** — Layer 1 is raw Unix, Layer 2 is LLM presentation
7. **Never drop stderr** — it's the info agents need most when commands fail

**What gets deleted:**
- `lib/elixir_ai_command_tool/` — the entire directory tree
- The `tools_api` MIX_ENV concept
- The `command_runner` Docker service's Elixir runtime

**What gets created:**
- `ElixirAi.CommandRunner` — Layer 1: `docker exec` transport, raw execution
- `ElixirAi.CommandRunner.Presentation` — Layer 2: binary guard, overflow, metadata, stderr
- `sandbox/Dockerfile` — bare Debian container with shell tools

---

## Architecture: Two-Layer Design

```
┌──────────────────────────────────────────────────────────┐
│  Layer 2: LLM Presentation (CommandRunner.Presentation)  │
│  Binary guard │ Overflow mode │ Metadata footer │ stderr  │
├──────────────────────────────────────────────────────────┤
│  Layer 1: Unix Execution (CommandRunner)                  │
│  docker exec │ bash -c │ pipes │ chains │ raw exit codes  │
└──────────────────────────────────────────────────────────┘
```

**Why two layers?** When `cat bigfile.txt | grep error | head 10` executes:

- Inside Layer 1: cat outputs 500KB raw text → grep filters → head takes 10 lines
- If you truncated cat's output in Layer 1 → grep only searches the first N lines (wrong results)
- If you injected `[exit:0]` in Layer 1 → it flows into grep as data (corrupted pipe)

Layer 1 must remain **raw, lossless, metadata-free**. All processing happens in
Layer 2, after the pipe chain completes and the final result is ready for the LLM.

---

## Step 1 — Delete the command tool tree

```bash
rm -rf lib/elixir_ai_command_tool/
```

This removes:
- `application.ex` — Supervisor that started Bandit + SocketServer
- `http/router.ex` — Plug router with POST /api/execute
- `http/client.ex` — Req-based HTTP client (replaced by docker exec)
- `http/protocol.ex` — JSON/socket encode/decode
- `runner/command_executor.ex` — System.cmd wrapper
- `runner/socket_server.ex` — Unix domain socket GenServer
- `runner/truncator.ex` — byte/line truncation
- `shims/runner.sh` — bash shim forwarding to socket
- `shims/generate_shims.sh` — symlink generator
- `entrypoint.sh` — container startup script
- `Dockerfile` — Elixir-based container image
- `config/config.exs` and `config/runtime.exs` — tool-specific config

---

## Step 2 — Create `ElixirAi.CommandRunner` (Layer 1: Execution)

Create `lib/elixir_ai/command_runner.ex`.

This is strictly the **execution layer** — raw Unix semantics, no formatting,
no metadata, no truncation. Pipes and chains work because `bash -c` handles
`|`, `&&`, `||`, `;` natively. The LLM already knows how to compose these from
billions of lines of shell in its training data.

**Key design:** stderr must be captured separately, never dropped. Use
`open_port` with `:stderr` or a shell wrapper (`bash -c '... 2>/tmp/.stderr'`)
so Layer 2 always has access to both streams.

```elixir
defmodule ElixirAi.CommandRunner do
  @moduledoc """
  Layer 1: Unix execution layer.

  Executes commands inside the sandbox container via `docker exec`.
  Returns raw {stdout, stderr, exit_code, duration_ms} — no truncation,
  no metadata injection, no formatting. Pipes and chains work natively
  because execution goes through `bash -c`.

  All LLM-facing processing happens in CommandRunner.Presentation (Layer 2).
  """

  require Logger

  @timeout 30_000

  @doc """
  Execute a shell command string via `bash -c` inside the sandbox container.

  The command string can contain pipes, chains, redirects — full bash syntax.
  Examples:
    run_bash("cat /var/log/app.log | grep ERROR | wc -l")
    run_bash("curl -sL $URL -o data.csv && cat data.csv | head 5")
    run_bash("cat config.yaml || echo 'config not found, using defaults'")

  Returns `{:ok, %{stdout, stderr, exit_code, duration_ms}}` or `{:error, reason}`.
  """
  def run_bash(shell_command) when is_binary(shell_command) do
    container = container_name()

    # Wrap command to capture stderr separately.
    # stdout goes to fd 1 (captured by System.cmd), stderr written to temp file,
    # then appended to stdout with a delimiter so we can split them apart.
    #
    # This ensures stderr is NEVER dropped — the single most important
    # principle for agent command execution.
    wrapped =
      ~s|sh -c '{ #{shell_command} ; } 2>/tmp/.cmd_stderr; __exit=$?; | <>
      ~s|if [ -s /tmp/.cmd_stderr ]; then | <>
      ~s|printf "\\n__STDERR_MARKER__\\n"; cat /tmp/.cmd_stderr; fi; | <>
      ~s|exit $__exit'|

    docker_args = ["exec", container, "bash", "-c", wrapped]

    Logger.info("CommandRunner: #{container} $ #{shell_command}")

    start_time = System.monotonic_time(:millisecond)

    try do
      {combined, exit_code} = System.cmd("docker", docker_args, stderr_to_stdout: true)
      duration_ms = System.monotonic_time(:millisecond) - start_time

      {stdout, stderr} = split_stderr(combined)

      {:ok, %{stdout: stdout, stderr: stderr, exit_code: exit_code, duration_ms: duration_ms}}
    rescue
      e ->
        Logger.error("CommandRunner failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Execute a raw command with arguments (no shell interpretation).
  Used for health checks and direct binary invocation.
  """
  def execute(command, args \\ []) when is_binary(command) and is_list(args) do
    container = container_name()
    docker_args = ["exec", container, command | args]

    start_time = System.monotonic_time(:millisecond)

    try do
      {output, exit_code} = System.cmd("docker", docker_args, stderr_to_stdout: true)
      duration_ms = System.monotonic_time(:millisecond) - start_time

      {:ok, %{stdout: output, stderr: "", exit_code: exit_code, duration_ms: duration_ms}}
    rescue
      e ->
        Logger.error("CommandRunner failed: #{Exception.message(e)}")
        {:error, Exception.message(e)}
    end
  end

  def health_check do
    case execute("echo", ["ok"]) do
      {:ok, %{stdout: stdout, exit_code: 0}} ->
        if String.contains?(stdout, "ok"), do: :ok, else: {:error, "unexpected output"}
      {:ok, %{exit_code: code}} ->
        {:error, "health check exit code #{code}"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- Private ----------------------------------------------------------------

  @stderr_marker "__STDERR_MARKER__"

  defp split_stderr(combined) do
    case String.split(combined, "\n#{@stderr_marker}\n", parts: 2) do
      [stdout, stderr] -> {String.trim_trailing(stdout), String.trim_trailing(stderr)}
      [stdout] -> {stdout, ""}
    end
  end

  defp container_name do
    Application.get_env(:elixir_ai, :sandbox_container) || "command_runner"
  end
end
```

> **Injection safety:** `System.cmd("docker", args)` passes arguments as a
> list — never interpolated into a shell string on the host. The `shell_command`
> is passed as a single arg to `bash -c` *inside the sandbox container*, which
> is the intended behavior (the AI composes shell pipelines in a sandbox).

---

## Step 3 — Create `ElixirAi.CommandRunner.Presentation` (Layer 2: LLM)

Create `lib/elixir_ai/command_runner/presentation.ex`.

This is the **presentation layer** — everything that transforms raw execution
results into text optimized for LLM cognition. It implements four mechanisms
from the blog post:

### Mechanism A: Binary Guard

Before returning anything to the LLM, detect binary content:
- Null byte (`\0`) detected → binary
- UTF-8 validation failed → binary
- Control character ratio > 10% → binary

Return a helpful error message instead of garbage tokens that would disrupt
the LLM's attention on surrounding valid content.

### Mechanism B: Overflow Mode

Output exceeds limits?
1. Truncate to first N lines (rune-safe, won't split UTF-8)
2. Write full output to `/tmp/cmd-output/cmd-{n}.txt` **inside the sandbox**
3. Return truncated output + metadata telling the LLM where the full output
   is and how to explore it (grep, tail, etc.)

The LLM already knows `grep`, `head`, `tail` — overflow mode transforms
"large data exploration" into a skill it already has.

### Mechanism C: Metadata Footer

Every result ends with `[exit:N | Xms]`. The LLM extracts two signals:
- **Exit codes** (Unix convention, LLMs already know): 0=success, 1=error, 127=not found
- **Duration** (cost awareness): 12ms=cheap, 3.2s=moderate, 45s=expensive

After seeing this pattern dozens of times in a conversation, the agent
internalizes it — anticipating failure from exit:1, reducing calls when
it sees long durations.

### Mechanism D: stderr Attachment

When a command fails with stderr, always attach it. Never drop it.
The blog post's cautionary tale: an agent ran `pip install pymupdf`, got
exit code 127. stderr contained `bash: pip: command not found` but it was
dropped. The agent blind-guessed 10 different package managers before
succeeding. If stderr had been visible, one call would have sufficed.

```elixir
defmodule ElixirAi.CommandRunner.Presentation do
  @moduledoc """
  Layer 2: LLM presentation layer.

  Transforms raw execution results into text optimized for LLM cognition.
  Implements four mechanisms:
    A. Binary guard — detect and reject binary output
    B. Overflow mode — truncate + persist full output for exploration
    C. Metadata footer — [exit:N | Xms] on every result
    D. stderr attachment — never drop error output

  This module NEVER runs during pipe execution (Layer 1). It only runs
  after the full command chain completes, on the final result.
  """

  alias ElixirAi.CommandRunner

  @max_bytes 50_000
  @max_lines 200
  @binary_control_char_threshold 0.10

  @doc """
  Format a raw execution result for the LLM.
  Applies: binary guard → overflow mode → stderr attachment → metadata footer.
  """
  def format(%{stdout: stdout, stderr: stderr, exit_code: exit_code, duration_ms: duration_ms}) do
    formatted_stdout = process_output(stdout)
    formatted_stderr = process_stderr(stderr, exit_code)

    body =
      case {formatted_stdout, formatted_stderr} do
        {"", ""} -> "(no output)"
        {out, ""} -> out
        {"", err} -> err
        {out, err} -> out <> "\n" <> err
      end

    body <> "\n" <> metadata_footer(exit_code, duration_ms)
  end

  # -- Mechanism A: Binary Guard -----------------------------------------------

  defp process_output(""), do: ""

  defp process_output(output) do
    cond do
      has_null_bytes?(output) ->
        size = byte_size(output)
        "[binary data (#{format_bytes(size)}). Pipe through a text filter or use a different command]"

      not String.valid?(output) ->
        size = byte_size(output)
        "[binary data (#{format_bytes(size)}), not valid UTF-8. Use a text-based command instead]"

      high_control_char_ratio?(output) ->
        size = byte_size(output)
        "[binary data (#{format_bytes(size)}), high control character ratio. Use a text-based command instead]"

      true ->
        overflow(output)
    end
  end

  defp has_null_bytes?(data), do: :binary.match(data, <<0>>) != :nomatch

  defp high_control_char_ratio?(data) do
    total = byte_size(data)
    if total == 0, do: false, else: count_control_chars(data) / total > @binary_control_char_threshold
  end

  defp count_control_chars(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.count(fn byte ->
      byte < 0x20 and byte not in [0x09, 0x0A, 0x0D]  # exclude tab, newline, carriage return
    end)
  end

  # -- Mechanism B: Overflow Mode ----------------------------------------------

  defp overflow(output) when byte_size(output) <= @max_bytes do
    truncate_lines(output)
  end

  defp overflow(output) do
    total_bytes = byte_size(output)
    total_lines = output |> String.split("\n") |> length()

    # Persist full output inside the sandbox for later exploration
    overflow_path = persist_overflow(output)

    # Truncate for LLM context
    shown = binary_part(output, 0, @max_bytes)
    truncated = truncate_lines(shown)

    truncated <>
      "\n\n--- output truncated (#{total_lines} lines, #{format_bytes(total_bytes)}) ---" <>
      overflow_navigation(overflow_path)
  end

  defp persist_overflow(output) do
    # Use a monotonic counter for unique filenames within the sandbox
    n = System.unique_integer([:positive])
    path = "/tmp/cmd-output/cmd-#{n}.txt"

    # Write the full output into the sandbox container via docker exec
    # Use stdin piping to avoid argument length limits
    CommandRunner.run_bash("mkdir -p /tmp/cmd-output && cat > #{path} <<'__OVERFLOW_EOF__'\n#{output}\n__OVERFLOW_EOF__")

    path
  end

  defp overflow_navigation(path) do
    """

    Full output: #{path}
    Explore with:
      cat #{path} | grep <pattern>
      cat #{path} | tail 100
      cat #{path} | head -n 50
      wc -l #{path}
    """
  end

  defp truncate_lines(output) do
    lines = String.split(output, "\n")

    if length(lines) > @max_lines do
      Enum.take(lines, @max_lines) |> Enum.join("\n")
    else
      output
    end
  end

  # -- Mechanism C: Metadata Footer --------------------------------------------

  defp metadata_footer(exit_code, duration_ms) do
    "[exit:#{exit_code} | #{format_duration(duration_ms)}]"
  end

  defp format_duration(ms) when ms < 1000, do: "#{ms}ms"
  defp format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"

  # -- Mechanism D: stderr Attachment ------------------------------------------

  defp process_stderr("", _exit_code), do: ""
  defp process_stderr(stderr, _exit_code), do: "[stderr] " <> String.trim(stderr)

  # -- Helpers -----------------------------------------------------------------

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes}B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)}KB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)}MB"
end
```

---

## Step 4 — Redesign the `run_command` tool in `ElixirAi.AiTools`

The blog post advocates a **single `run` tool** with a dynamically generated
description that lists available commands. This replaces the current
`run_command` tool with its static description.

### Tool description: Level 0 progressive discovery

The tool description is generated at conversation start, listing available
commands with one-line summaries. This is **Level 0** of the progressive
help system — the agent knows what's available without consuming context on
every parameter of every command.

### Levels 1-2 are free

Since we run real bash in a real container, `--help` works natively on every
installed tool. The agent can call `run(command="grep --help")` or just
`run(command="grep")` (which prints usage on missing args). We don't need to
build progressive discovery — Unix already has it.

### Error messages as navigation

When a command fails, stderr + exit code tells the agent what to do next.
Exit 127 = command not found (agent knows to try alternatives). The binary
guard in Layer 2 says "use a different command" instead of returning garbage.
This is technique 2 from the blog: every error points to the right direction.

**In `lib/elixir_ai/ai_tools/ai_tools.ex`:**

Rename `run_command` → `run` (single tool, matches blog pattern).

Update `@server_tool_names` to replace `"run_command"` with `"run"`.

```elixir
def run(server) do
  ai_tool(
    name: "run",
    description: """
    Execute a command in the sandboxed container. Supports full bash syntax
    including pipes (|), chains (&&, ||), semicolons (;), and redirects.

    One call can be a complete workflow:
      cat log.txt | grep ERROR | wc -l
      curl -sL $URL -o data.csv && head -5 data.csv
      cat config.yaml || echo "not found, using defaults"

    Available tools in the sandbox:
      cat, head, tail, less     — read files
      grep, sed, awk            — filter and transform text
      sort, uniq, wc, tr, cut   — text processing
      find, ls, tree, file      — explore filesystem
      curl, wget                — fetch URLs
      jq                        — parse JSON
      git                       — version control
      bash                      — scripting

    Use --help on any command for detailed usage (e.g. "grep --help").
    Large outputs are automatically truncated with a path to the full file.
    """,
    function: fn args ->
      command = Map.fetch!(args, "command")

      case ElixirAi.CommandRunner.run_bash(command) do
        {:ok, result} ->
          {:ok, ElixirAi.CommandRunner.Presentation.format(result)}

        {:error, reason} ->
          {:ok, "[error] runner unavailable: #{reason}\n[exit:1 | 0ms]"}
      end
    end,
    parameters: %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "Shell command to execute (e.g. \"ls -la\", \"cat file.txt | grep foo\")"
        }
      },
      "required" => ["command"]
    },
    server: server
  )
end
```

---

## Step 5 — Remove `tools_api` from `ElixirAi.Application`

In `lib/elixir_ai/application.ex`, delete the `tools_api` branch entirely:

**Delete these lines:**
```elixir
children =
  case Application.get_env(:elixir_ai, :env) do
    :tools_api -> tools_api_children()
    _ -> full_children()
  end

...

defp tools_api_children do
  [
    {ElixirAiCommandTool.Application, []}
  ]
end
```

**Replace with:**
```elixir
children = full_children()
```

---

## Step 6 — Clean up config files

### `config/runtime.exs`

**Delete** the `tools_api` branch at the top:

```elixir
# DELETE THIS BLOCK:
if config_env() == :tools_api do
  config :elixir_ai,
    command_tool_port: String.to_integer(System.get_env("COMMAND_TOOL_PORT") || "4001")
else
  ...
end
```

**Replace with** (no conditional):
```elixir
config :elixir_ai,
  ai_endpoint: System.get_env("AI_RESPONSES_ENDPOINT"),
  ai_token: System.get_env("AI_TOKEN"),
  ai_model: System.get_env("AI_MODEL"),
  whisper_endpoint: System.get_env("WHISPER_ENDPOINT"),
  sandbox_container: System.get_env("SANDBOX_CONTAINER") || "command_runner"
```

Remove `command_tool_url` — no longer needed (we use the container name
directly via `docker exec`, not an HTTP URL).

### `docker-compose.yml` — node environment

Remove `COMMAND_TOOL_URL: http://command_runner:4001` from node1/node2 env.

No replacement needed — the container name `command_runner` is hard-coded as
the default and overridable via `SANDBOX_CONTAINER`.

### Other config files

No changes needed to `config.exs`, `dev.exs`, `prod.exs`, or `test.exs`.

---

## Step 7 — Create the sandbox container

Create `sandbox/Dockerfile`. This is a bare container with just shell tools —
no Elixir runtime, no HTTP server, no sockets, no shims. Commands are injected
via `docker exec` from the host.

The tool list here corresponds to the "Available tools" listed in the `run`
tool description (Step 4). If you add tools here, update the description too.

```dockerfile
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  coreutils \
  grep \
  sed \
  gawk \
  findutils \
  curl \
  wget \
  git \
  jq \
  tree \
  file \
  less \
  procps \
  ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Overflow mode writes full output here for the agent to explore later
RUN mkdir -p /tmp/cmd-output

# Create a non-root user for the sandbox
RUN useradd -m -s /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox

# Container does nothing on its own. Commands injected via `docker exec`.
CMD ["sleep", "infinity"]
```

---

## Step 8 — Update `docker-compose.yml`

Replace the `command_runner` service:

**Before:**
```yaml
command_runner:
  build:
    context: .
    dockerfile: lib/elixir_ai_command_tool/Dockerfile
  container_name: command_runner
  hostname: command_runner
  environment:
    COMMAND_TOOL_PORT: 4001
  expose:
    - "4001"
  healthcheck:
    test: ["CMD", "curl", "-sf", "http://localhost:4001/api/execute", ...]
    ...
```

**After:**
```yaml
command_runner:
  build:
    context: ./sandbox
    dockerfile: Dockerfile
  container_name: command_runner
  hostname: command_runner
  healthcheck:
    test: ["CMD", "echo", "ok"]
    interval: 10s
    timeout: 5s
    retries: 3
```

Main app containers need Docker socket access for `System.cmd("docker", ...)`:

```yaml
node1:
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock
    ...
```

Remove `COMMAND_TOOL_URL` from node1/node2 environment.
Remove `depends_on: command_runner` from node1 (or keep for startup ordering).

> **Security note:** Mounting the Docker socket gives full Docker API access.
> In production, consider a restricted proxy like docker-socket-proxy or
> switch to SSH-based execution (see Alternative section).

---

## Step 9 — Update the main `Dockerfile` (production)

Add `docker-cli` to the runtime image so `System.cmd("docker", ...)` works:

```dockerfile
FROM elixir:1.19.5-otp-28-alpine AS runtime
RUN apk add --no-cache libstdc++ openssl ncurses-libs docker-cli
```

---

## Step 10 — Verify

```bash
# 1. Delete the old command tool
rm -rf lib/elixir_ai_command_tool/

# 2. Create the new modules (Steps 2, 3) and sandbox Dockerfile (Step 7)

# 3. Compile — should have zero references to ElixirAiCommandTool
mix compile 2>&1 | grep -i "ElixirAiCommandTool"
# (should output nothing)

# 4. Build and run
docker compose build
docker compose up -d

# 5. Test: simple command
docker compose exec node1 sh -c 'mix run -e "
  {:ok, r} = ElixirAi.CommandRunner.run_bash(\"ls -la /\")
  IO.puts ElixirAi.CommandRunner.Presentation.format(r)
"'

# 6. Test: pipe chain (one call, three commands)
docker compose exec node1 sh -c 'mix run -e "
  {:ok, r} = ElixirAi.CommandRunner.run_bash(\"echo -e \\\"a\nb\nc\nd\\\" | grep -c .\")
  IO.puts ElixirAi.CommandRunner.Presentation.format(r)
"'

# 7. Test: binary guard (should reject, not pass garbage)
docker compose exec node1 sh -c 'mix run -e "
  {:ok, r} = ElixirAi.CommandRunner.run_bash(\"head -c 100 /usr/bin/ls\")
  IO.puts ElixirAi.CommandRunner.Presentation.format(r)
"'

# 8. Test: stderr capture (exit 127, stderr visible)
docker compose exec node1 sh -c 'mix run -e "
  {:ok, r} = ElixirAi.CommandRunner.run_bash(\"nonexistent_command\")
  IO.puts ElixirAi.CommandRunner.Presentation.format(r)
"'
# Should show: [stderr] bash: nonexistent_command: command not found
#              [exit:127 | Xms]

# 9. Run the test suite
mix test
```

---

## Alternative: SSH instead of Docker socket

If mounting the Docker socket is unacceptable (e.g., security policy), use
SSH into the sandbox container instead:

1. Install `openssh-server` in the sandbox Dockerfile
2. Generate a keypair at build time or mount one
3. Replace `System.cmd("docker", ["exec", ...])` with
   `System.cmd("ssh", ["-o", "StrictHostKeyChecking=no", "sandbox@command_runner", command])`

The module interface (`run_bash/1`, `execute/2`) stays identical — only the
transport changes. Layer 2 is completely unaffected.

---

## Step 11 — Human approval gate for sandbox commands

### Problem

The AI can call `run(command="rm -rf /home/sandbox/*")` and it executes
immediately. Reads are generally safe, but writes, deletes, installs, and
network operations need informed human consent.

### Design: Command classifier + approval gate in the tool dispatch loop

The approval system sits **between** the AI requesting a tool call and the
tool function executing. It works at three levels:

1. **Command classifier** — categorizes commands as `auto_allow` or `requires_approval`
2. **Approval gate** — pauses execution, notifies the LiveView, waits for user response
3. **User preferences** — per-conversation configurable policy for what's auto-allowed

```
AI requests run(command="...") 
  → StreamHandler.handle(:ai_tool_call_end, ...)
    → CommandApproval.classify(command, policy)
      → :auto_allow  → execute immediately (current behavior)
      → :needs_approval → broadcast to LiveView, park the tool call, wait
        → User clicks Allow → execute
        → User clicks Deny → return "[denied] User declined this command"
        → Timeout (configurable) → deny with "[denied] Approval timed out"
```

### Architecture

```
┌──────────────────────────────────────────────────┐
│  CommandApproval (new module)                     │
│  classify/2 → :auto_allow | :needs_approval      │
│  Built-in rules + user-configurable policy        │
├──────────────────────────────────────────────────┤
│  StreamHandler (modified)                         │
│  Tool dispatch checks classifier before executing │
│  Parks pending approvals, handles user response    │
├──────────────────────────────────────────────────┤
│  ChatLive (modified)                              │
│  Shows approval notification with command preview  │
│  Allow/Deny buttons → sends response to ChatRunner │
└──────────────────────────────────────────────────┘
```

### Step 11a — Create `ElixirAi.CommandApproval`

Create `lib/elixir_ai/command_approval.ex`.

This module classifies shell commands by parsing the **first command word**
(the verb) from the bash string. It doesn't try to understand full bash
semantics — it pattern-matches the leading command to decide safety.

```elixir
defmodule ElixirAi.CommandApproval do
  @moduledoc """
  Classifies sandbox commands as auto-allowed or requiring human approval.

  Default policy: reads are auto-allowed, writes require approval.
  Users can customize per-conversation via `approval_policy`.

  The classifier examines the first command in a pipeline and every command
  after `&&`, `||`, or `;` chain operators. If ANY segment requires approval,
  the whole command requires approval.
  """

  @doc """
  Classify a shell command string against a policy.
  Returns `:auto_allow` or `{:needs_approval, reason}`.
  """
  def classify(command, policy \\ default_policy()) do
    segments = split_chain_segments(command)

    case Enum.find_value(segments, fn seg -> check_segment(seg, policy) end) do
      nil -> :auto_allow
      reason -> {:needs_approval, reason}
    end
  end

  @doc """
  Returns the default policy map. Users override specific keys.
  """
  def default_policy do
    %{
      # Commands that are always auto-allowed (read-only operations)
      auto_allow: MapSet.new([
        "cat", "head", "tail", "less", "more",
        "grep", "egrep", "fgrep", "rg",
        "find", "ls", "tree", "file", "stat", "du", "df",
        "wc", "sort", "uniq", "tr", "cut", "paste", "column",
        "awk", "sed",       # note: sed without -i is read-only, but sed -i is a write.
                             # the flag check below catches sed -i specifically.
        "echo", "printf", "true", "false",
        "date", "cal", "env", "printenv", "whoami", "id", "uname", "hostname",
        "jq", "diff", "comm", "basename", "dirname", "realpath", "readlink",
        "which", "type", "command", "test",
        "expr", "bc", "seq",
        "man", "help", "info",
        "git log", "git status", "git diff", "git show", "git branch", "git tag",
      ]),

      # Commands that always require approval (destructive or side-effecting)
      always_approve: MapSet.new([
        "rm", "rmdir", "mkfs", "dd",
        "chmod", "chown", "chgrp",
        "kill", "killall", "pkill",
        "shutdown", "reboot", "halt",
        "mount", "umount",
        "apt", "apt-get", "dpkg", "pip", "pip3", "npm", "yarn",
        "git push", "git commit", "git reset", "git checkout", "git merge", "git rebase",
        "docker", "kubectl",
        "sudo", "su",
        "ssh", "scp", "rsync",
        "nc", "ncat", "socat",
      ]),

      # Flags that escalate any command to require approval
      write_flags: ["-i", "--in-place", "-w", "--write", "-o", "--output"],

      # Patterns in the command that require approval (redirects that write)
      write_patterns: [~r/\s>(?!>)\s*\S/, ~r/\s>>\s*\S/, ~r/\btee\b/],
    }
  end

  # -- Internal ---------------------------------------------------------------

  # Split on chain operators: &&, ||, ;
  # We don't split on | (pipe) because pipes don't start new commands that
  # could independently be destructive — data flows, not control.
  defp split_chain_segments(command) do
    command
    |> String.split(~r/\s*(?:&&|\|\||;)\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp check_segment(segment, policy) do
    cmd = extract_command_name(segment)

    cond do
      # Check two-word commands first (e.g. "git push", "git commit")
      two_word_match?(segment, policy.always_approve) ->
        "#{two_word_cmd(segment)} requires approval"

      MapSet.member?(policy.always_approve, cmd) ->
        "#{cmd} requires approval"

      two_word_match?(segment, policy.auto_allow) ->
        nil

      MapSet.member?(policy.auto_allow, cmd) ->
        # Check for write flags that escalate a read command
        check_write_escalation(segment, cmd, policy)

      true ->
        # Unknown command — require approval (safe default)
        "unknown command '#{cmd}' requires approval"
    end
  end

  defp extract_command_name(segment) do
    segment |> String.split(~r/\s+/, parts: 2) |> List.first() |> to_string()
  end

  defp two_word_cmd(segment) do
    segment |> String.split(~r/\s+/, parts: 3) |> Enum.take(2) |> Enum.join(" ")
  end

  defp two_word_match?(segment, set) do
    MapSet.member?(set, two_word_cmd(segment))
  end

  defp check_write_escalation(segment, cmd, policy) do
    has_write_flag =
      Enum.any?(policy.write_flags, fn flag ->
        String.contains?(segment, flag)
      end)

    has_write_pattern =
      Enum.any?(policy.write_patterns, fn pattern ->
        Regex.match?(pattern, segment)
      end)

    cond do
      has_write_flag -> "#{cmd} with write flag requires approval"
      has_write_pattern -> "output redirect requires approval"
      true -> nil
    end
  end
end
```

**Key design decisions:**
- **Unknown commands default to requiring approval** — safe by default
- **Pipe operators (`|`) don't split** — data flows through pipes, they're compositional
- **Chain operators (`&&`, `||`, `;`) do split** — each segment is an independent command
- **Two-word commands** — `git push` is different from `git log`
- **Write flag detection** — catches `sed -i` (write) vs bare `sed` (read)
- **Redirect detection** — `>` and `>>` (write to file) always need approval
- **`tee` detection** — writes to file while passing through pipe

### Step 11b — Create approval policy persistence

Add a `tool_approval_policy` JSONB column to the `conversations` table,
or store it as a user-level preference. For per-conversation:

```sql
ALTER TABLE conversations
ADD COLUMN tool_approval_policy jsonb DEFAULT NULL;
```

`NULL` means "use default policy." Otherwise it stores overrides:

```json
{
  "auto_allow_additions": ["tee", "sed -i", "git commit"],
  "require_approval_additions": ["curl"],
  "auto_allow_all": false
}
```

Add to `ElixirAi.Conversation`:
- `find_approval_policy/1` — load from DB
- `update_approval_policy/2` — save overrides

The policy struct merges user overrides on top of the default:

```elixir
def merged_policy(user_overrides) when is_map(user_overrides) do
  base = default_policy()

  auto_allow =
    base.auto_allow
    |> MapSet.union(MapSet.new(Map.get(user_overrides, "auto_allow_additions", [])))
    |> MapSet.difference(MapSet.new(Map.get(user_overrides, "require_approval_additions", [])))

  always_approve =
    base.always_approve
    |> MapSet.union(MapSet.new(Map.get(user_overrides, "require_approval_additions", [])))
    |> MapSet.difference(MapSet.new(Map.get(user_overrides, "auto_allow_additions", [])))

  %{base | auto_allow: auto_allow, always_approve: always_approve}
end
```

### Step 11c — Modify `ChatUtils.ai_tool/1` to support approval

The approval gate wraps the tool's `function` callback. When `classify/2`
returns `:needs_approval`, instead of calling the function immediately,
the `run_function` lambda:

1. Broadcasts `{:tool_approval_request, tool_call_id, command, reason}` via PubSub
2. Blocks (in the Task) waiting for a reply via `receive`
3. On `:approved` → executes the function and sends the tool response
4. On `:denied` → sends a denial message as the tool response

Modify the `run` tool definition in `AiTools` (not `ai_tool/1` itself —
keep the generic helper clean):

```elixir
def run(server) do
  ai_tool(
    name: "run",
    description: "...",
    function: fn args ->
      command = Map.fetch!(args, "command")
      policy = get_approval_policy(server)  # loaded from ChatRunner state

      case ElixirAi.CommandApproval.classify(command, policy) do
        :auto_allow ->
          execute_command(command)

        {:needs_approval, reason} ->
          request_approval(server, command, reason)
      end
    end,
    parameters: %{...},
    server: server
  )
end

defp execute_command(command) do
  case ElixirAi.CommandRunner.run_bash(command) do
    {:ok, result} ->
      {:ok, ElixirAi.CommandRunner.Presentation.format(result)}
    {:error, reason} ->
      {:ok, "[error] runner unavailable: #{reason}\n[exit:1 | 0ms]"}
  end
end

defp request_approval(server, command, reason) do
  # Register this process so it can receive the approval response
  ref = make_ref()
  send(server, {:register_pending_approval, ref, self()})

  # Broadcast approval request to the LiveView
  name = GenServer.call(server, :get_name)
  Phoenix.PubSub.broadcast(
    ElixirAi.PubSub,
    "ai_chat:#{name}",
    {:tool_approval_request, ref, command, reason}
  )

  # Block waiting for user response (with timeout)
  receive do
    {:approval_response, ^ref, :approved} ->
      execute_command(command)

    {:approval_response, ^ref, :denied} ->
      {:ok, "[denied] User declined: #{command}\n[exit:1 | 0ms]"}
  after
    120_000 ->
      {:ok, "[denied] Approval timed out after 2 minutes: #{command}\n[exit:1 | 0ms]"}
  end
end
```

### Step 11d — Add ChatRunner state for pending approvals

In the ChatRunner GenServer, add:
- `pending_approvals: %{}` to state — maps `ref → task_pid`
- Handle `{:register_pending_approval, ref, pid}` — stores the mapping
- Handle `{:approval_decision, ref, :approved | :denied}` — forwards to the waiting task

```elixir
# In ChatRunner handle_info:

def handle_info({:register_pending_approval, ref, pid}, state) do
  {:noreply, put_in(state.pending_approvals[ref], pid)}
end

# Called by the LiveView via GenServer.cast or PubSub:
def handle_cast({:approval_decision, ref, decision}, state) do
  case Map.pop(state.pending_approvals, ref) do
    {nil, _} -> {:noreply, state}
    {pid, new_approvals} ->
      send(pid, {:approval_response, ref, decision})
      {:noreply, %{state | pending_approvals: new_approvals}}
  end
end
```

### Step 11e — LiveView approval UI

In `ChatLive`, handle the approval broadcast and render an inline notification:

```elixir
# In chat_live.ex handle_info:

def handle_info({:tool_approval_request, ref, command, reason}, socket) do
  approval = %{ref: ref, command: command, reason: reason, timestamp: DateTime.utc_now()}

  {:noreply,
   socket
   |> update(:pending_approvals, &[approval | &1])}
end

# In chat_live.ex handle_event:

def handle_event("approve_command", %{"ref" => ref_string}, socket) do
  ref = decode_ref(ref_string)
  ElixirAi.ChatRunner.approval_decision(socket.assigns.chat_name, ref, :approved)

  {:noreply,
   socket
   |> update(:pending_approvals, &Enum.reject(&1, fn a -> a.ref == ref end))}
end

def handle_event("deny_command", %{"ref" => ref_string}, socket) do
  ref = decode_ref(ref_string)
  ElixirAi.ChatRunner.approval_decision(socket.assigns.chat_name, ref, :denied)

  {:noreply,
   socket
   |> update(:pending_approvals, &Enum.reject(&1, fn a -> a.ref == ref end))}
end
```

**The UI component** renders as a sticky notification bar or inline card:

```heex
<div :for={approval <- @pending_approvals} class="bg-amber-50 border border-amber-300 rounded-lg p-4 mb-2">
  <div class="flex items-start gap-3">
    <div class="flex-shrink-0 text-amber-600">⚠️</div>
    <div class="flex-1 min-w-0">
      <p class="text-sm font-medium text-amber-800">Command requires approval</p>
      <p class="text-xs text-amber-600 mt-0.5"><%= approval.reason %></p>
      <pre class="mt-2 p-2 bg-amber-100 rounded text-sm font-mono text-amber-900 overflow-x-auto"><%= approval.command %></pre>
      <div class="mt-3 flex gap-2">
        <button phx-click="approve_command" phx-value-ref={encode_ref(approval.ref)}
                class="px-3 py-1.5 bg-green-600 text-white text-sm rounded hover:bg-green-700">
          Allow
        </button>
        <button phx-click="deny_command" phx-value-ref={encode_ref(approval.ref)}
                class="px-3 py-1.5 bg-red-600 text-white text-sm rounded hover:bg-red-700">
          Deny
        </button>
        <button phx-click="approve_command" phx-value-ref={encode_ref(approval.ref)}
                class="px-3 py-1.5 bg-gray-200 text-gray-700 text-sm rounded hover:bg-gray-300"
                title="Also auto-allow this command pattern in the future">
          Always Allow
        </button>
      </div>
    </div>
  </div>
</div>
```

The **"Always Allow"** button adds the command to the user's
`auto_allow_additions` in `tool_approval_policy` so it won't ask again.

### Step 11f — Approval settings UI

Extend the existing `ChatToolsLive` popup (which already has tool toggles)
with an "Approval Policy" section. Users can:

1. **Toggle "Auto-allow all"** — disables the approval system entirely
2. **View auto-allowed categories** — reads, text processing, filesystem exploration
3. **Add commands to auto-allow** — e.g. "always allow `tee`"
4. **Add commands to always-approve** — e.g. "always ask before `curl`"
5. **Reset to defaults**

This edits the `tool_approval_policy` JSONB column on the conversation.

### Summary of approval system

| Component                            | What it does                                               |
| ------------------------------------ | ---------------------------------------------------------- |
| `ElixirAi.CommandApproval`           | Classifies commands as safe/needs-approval based on policy |
| `conversations.tool_approval_policy` | Per-conversation user overrides (JSONB)                    |
| Tool `run` function                  | Checks classifier, gates on approval before executing      |
| ChatRunner state                     | Tracks `pending_approvals` map, routes approval decisions  |
| ChatLive UI                          | Shows amber notification card with Allow/Deny/Always Allow |
| ChatToolsLive settings               | Approval policy editor in existing tool config popup       |

### Default behavior (no configuration needed)

**Auto-allowed (reads):**
`cat`, `head`, `tail`, `less`, `grep`, `find`, `ls`, `tree`, `wc`, `sort`,
`uniq`, `awk`, `sed`, `echo`, `jq`, `diff`, `git log`, `git status`,
`git diff`, `git show`, `git branch`, etc.

**Requires approval (writes/side-effects):**
`rm`, `chmod`, `chown`, `kill`, `apt`, `pip`, `npm`, `git push`,
`git commit`, `docker`, `sudo`, `ssh`, any output redirect (`>`, `>>`, `tee`),
any command with `-i`/`--in-place` flag, any **unknown** command.

---

## Design mapping: Blog post concepts → Implementation

| Blog concept                           | Implementation                                                            |
| -------------------------------------- | ------------------------------------------------------------------------- |
| **Single `run` tool**                  | One `run(command="...")` in AiTools, replaces `run_command`               |
| **Pipes & chains**                     | `bash -c` handles `\|`, `&&`, `\|\|`, `;` natively — no parser needed     |
| **Level 0: command list injection**    | `run` tool description lists all sandbox commands with one-line summaries |
| **Level 1: command (no args) → usage** | Real bash tools already do this (`grep` with no args prints usage)        |
| **Level 2: subcommand → parameters**   | Real `--help` flags work in the sandbox                                   |
| **Error messages as navigation**       | stderr always attached; binary guard says what to use instead             |
| **Binary guard**                       | `Presentation.process_output/1` checks null bytes, UTF-8, control chars   |
| **Overflow mode**                      | Truncate + persist to `/tmp/cmd-output/cmd-N.txt` + suggest grep/tail     |
| **Metadata footer**                    | `[exit:N \| Xms]` appended to every result                                |
| **Never drop stderr**                  | Shell wrapper captures stderr separately via temp file + marker           |
| **Duration / cost awareness**          | `duration_ms` measured in Layer 1, formatted in Layer 2 footer            |
| **Sandbox isolation**                  | Bare Debian container, non-root user, no network escalation               |
| **Two-layer architecture**             | `CommandRunner` (Layer 1) + `CommandRunner.Presentation` (Layer 2)        |
| **Human approval gate**                | `CommandApproval` classifier + LiveView allow/deny UI                     |
| **Reads auto-allowed, writes gated**   | Default policy: read commands pass, writes/unknown need approval          |
| **User-configurable policy**           | Per-conversation `tool_approval_policy` JSONB overrides                   |

---

## Summary of file changes

| Action      | Path                                                 | What                                                                              |
| ----------- | ---------------------------------------------------- | --------------------------------------------------------------------------------- |
| **DELETE**  | `lib/elixir_ai_command_tool/`                        | Entire directory tree (13 files)                                                  |
| **CREATE**  | `lib/elixir_ai/command_runner.ex`                    | Layer 1: docker exec, stderr capture, duration timing                             |
| **CREATE**  | `lib/elixir_ai/command_runner/presentation.ex`       | Layer 2: binary guard, overflow, metadata footer, stderr                          |
| **CREATE**  | `sandbox/Dockerfile`                                 | Bare Debian container with shell tools                                            |
| **EDIT**    | `lib/elixir_ai/ai_tools/ai_tools.ex`                 | `run_command` → `run`, dynamic description, new module refs                       |
| **EDIT**    | `lib/elixir_ai/application.ex`                       | Remove `tools_api` branch and `tools_api_children/0`                              |
| **EDIT**    | `config/runtime.exs`                                 | Remove `tools_api` block, remove `command_tool_url`, add `sandbox_container`      |
| **EDIT**    | `docker-compose.yml`                                 | Simplify `command_runner` service, mount Docker socket, remove `COMMAND_TOOL_URL` |
| **EDIT**    | `Dockerfile`                                         | Add `docker-cli` to runtime stage                                                 |
| **CREATE**  | `lib/elixir_ai/command_approval.ex`                  | Command classifier: auto_allow vs needs_approval + policy merging                 |
| **EDIT**    | `lib/elixir_ai_web/features/chat/stream_handler.ex`  | Route approval decisions from ChatRunner to waiting tool tasks                    |
| **EDIT**    | `lib/elixir_ai_web/features/chat/chat_live.ex`       | Approval notification UI: Allow/Deny/Always Allow buttons                         |
| **EDIT**    | `lib/elixir_ai_web/features/chat/chat_tools_live.ex` | Approval policy settings in existing tool config popup                            |
| **MIGRATE** | `conversations` table                                | Add `tool_approval_policy` JSONB column                                           |
| **EDIT**    | `lib/elixir_ai/data/conversation.ex`                 | `find_approval_policy/1`, `update_approval_policy/2`                              |
