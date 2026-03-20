Below is a **structured design document** intended for another LLM (or engineer) to implement a **persistent BEAM-backed CLI execution system inside a long-lived Docker container using `docker exec`**.

---

# Design Document: Persistent BEAM Tool Runner in Docker

## 1. Objective

Build a system where:

* A **single long-lived Docker container** hosts:

  * a **persistent Elixir (BEAM) daemon**
  * a standard **bash execution environment**
* All commands are executed via:

  ```bash
  docker exec <container> bash -lc "<command>"
  ```
* Common tools (`cat`, `grep`, etc.) are **intercepted via PATH shims**
* Shims delegate execution to the **persistent BEAM daemon**
* The daemon:

  * executes real system commands
  * truncates output deterministically
  * returns `{stdout, stderr, exit_code}`

---

## 2. Non-Goals

* No AI/model integration
* No streaming output (batch only)
* No advanced sandboxing (seccomp/cgroups optional later)
* No distributed execution

---

## 3. System Overview

```text
Host
 └─ docker exec
     └─ Container (long-lived)
         ├─ bash
         │   └─ cat / grep / etc → shim (shell script)
         │        └─ Unix socket request
         │             └─ BEAM daemon
         │                  └─ System.cmd("cat", ...)
         │                  └─ truncate output
         │                  └─ return response
```

---

## 4. Key Design Decisions

### 4.1 Persistent Container

* Container is started once and reused
* Avoid `docker run` per command

### 4.2 Persistent BEAM Process

* Avoid BEAM startup per command
* Centralize execution + truncation

### 4.3 Bash as Execution Engine

* Do not reimplement shell parsing
* Support pipes, redirects, chaining

### 4.4 PATH Interception

* Replace selected binaries with shims
* Keep system binaries available underneath

---

## 5. Container Specification

### 5.1 Base Image

* `debian:bookworm-slim`

### 5.2 Required Packages

```bash
elixir
erlang
bash
socat
coreutils
grep
```

---

### 5.3 Filesystem Layout

```text
/app
  daemon.exs
  shims/
    cat
    grep
```

---

### 5.4 PATH Configuration

```bash
PATH=/app/shims:/usr/bin:/bin
```

---

### 5.5 Container Startup Command

```bash
elixir daemon.exs & exec bash
```

Requirements:

* daemon must start before shell usage
* shell must remain interactive/alive

---

## 6. BEAM Daemon Specification

### 6.1 Transport

* Unix domain socket:

  ```text
  /tmp/tool_runner.sock
  ```

* Protocol:

  * request: single line
  * response: Erlang binary (`:erlang.term_to_binary/1`)

---

### 6.2 Request Format (v1)

```text
<command>\t<arg1>\t<arg2>\n
```

Example:

```text
cat\tfile.txt\n
```

---

### 6.3 Response Format

```elixir
{stdout :: binary, stderr :: binary, exit_code :: integer}
```

Encoded via:

```elixir
:erlang.term_to_binary/1
```

---

### 6.4 Execution Logic

For each request:

1. Parse command + args
2. Call:

```elixir
System.cmd(cmd, args, stderr_to_stdout: false)
```

3. Apply truncation (see below)
4. Return encoded response

---

### 6.5 Truncation Rules

Configurable constants:

```elixir
@max_bytes 4000
@max_lines 200
```

Apply in order:

1. truncate by bytes
2. truncate by lines

Append:

```text
...[truncated]
```

---

### 6.6 Concurrency Model

* Accept loop via `:gen_tcp.accept`
* Each client handled in separate lightweight process (`spawn`)
* No shared mutable state required

---

### 6.7 Error Handling

* Unknown command → return exit_code 127
* Exceptions → return exit_code 1 + error message
* Socket failure → ignore safely

---

## 7. Shim Specification

### 7.1 Purpose

* Replace system binaries (`cat`, `grep`)
* Forward calls to daemon
* Reproduce exact CLI behavior:

  * stdout
  * stderr
  * exit code

---

### 7.2 Implementation Language

* Bash (fast startup, no BEAM overhead)

---

### 7.3 Behavior

For command:

```bash
cat file.txt
```

Shim must:

1. Build request string
2. Send to socket via `socat`
3. Receive binary response
4. Decode response
5. Write:

   * stdout → STDOUT
   * stderr → STDERR
6. Exit with correct code

---

### 7.4 Request Construction (in-memory)

No temp files.

```bash
{
  printf "cat"
  for arg in "$@"; do
    printf "\t%s" "$arg"
  done
  printf "\n"
} | socat - UNIX-CONNECT:/tmp/tool_runner.sock
```

---

### 7.5 Response Decoding

Temporary approach:

```bash
elixir -e '
  {out, err, code} = :erlang.binary_to_term(IO.read(:stdio, :all))
  IO.write(out)
  if err != "", do: IO.write(:stderr, err)
  System.halt(code)
'
```

---

### 7.6 Known Limitation

* Arguments containing tabs/newlines will break protocol
* Acceptable for v1
* Future: switch to JSON protocol

---

## 8. Execution Flow Example

```bash
docker exec container bash -lc "cat file.txt | grep foo"
```

Inside container:

1. `cat` → shim
2. shim → daemon → real `cat`
3. truncated output returned
4. piped to `grep`
5. `grep` → shim → daemon → real `grep`

---

## 9. Performance Expectations

| Component     | Latency   |
| ------------- | --------- |
| docker exec   | 10–40 ms  |
| shim + socket | 1–5 ms    |
| System.cmd    | 1–5 ms    |
| total         | ~15–50 ms |

---

## 10. Security Considerations

Minimal (v1):

* No command filtering
* Full shell access inside container

Future:

* allowlist commands
* resource limits
* seccomp profile

---

## 11. Extensibility

### 11.1 Add new tools

* create shim in `/app/shims`
* no daemon change required

---

### 11.2 Central policies

Implement in daemon:

* timeouts
* logging
* output shaping
* auditing

---

### 11.3 Protocol upgrade path

Replace tab protocol with:

```json
{ "cmd": "...", "args": [...] }
```

---

## 12. Failure Modes

| Failure            | Behavior                      |
| ------------------ | ----------------------------- |
| daemon not running | shim fails (connection error) |
| socket missing     | immediate error               |
| malformed response | decode failure                |
| command not found  | exit 127                      |

---

## 13. Implementation Checklist

* [ ] Dockerfile builds successfully
* [ ] daemon starts on container launch
* [ ] socket created at `/tmp/tool_runner.sock`
* [ ] shim intercepts commands via PATH
* [ ] shim communicates with daemon
* [ ] stdout/stderr preserved
* [ ] exit codes preserved
* [ ] truncation enforced

---

## 14. Minimal Acceptance Test

```bash
docker exec container bash -lc "echo hello"
docker exec container bash -lc "cat /etc/passwd | grep root"
docker exec container bash -lc "cat large_file.txt"
```

Verify:

* correct output
* truncated when large
* no noticeable delay beyond ~50ms

---

## 15. Summary

This system:

* avoids BEAM startup overhead
* preserves Unix execution semantics
* centralizes control in Elixir
* remains simple and composable

It matches the intended pattern:

> “Use the real environment, intercept selectively, and control outputs centrally.”
