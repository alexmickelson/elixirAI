#!/usr/bin/env bash
# Generic shim: forwards command execution to the BEAM daemon
# via the internal Unix socket at /tmp/tool_runner.sock.
#
# Each named shim (cat, grep, etc.) is a symlink to this script.
# The shim extracts the command name from $0 and sends it along
# with all arguments to the daemon.

SOCKET="/tmp/tool_runner.sock"
CMD="$(basename "$0")"

# Build tab-delimited request
REQUEST="$CMD"
for arg in "$@"; do
  REQUEST="${REQUEST}\t${arg}"
done
REQUEST="${REQUEST}\n"

# Send request and decode response
printf "$REQUEST" | socat - UNIX-CONNECT:"$SOCKET" | \
  elixir -e '
    data = IO.read(:stdio, :eof)
    case data do
      :eof ->
        IO.write(:stderr, "runner: no response from daemon\n")
        System.halt(1)
      _ ->
        {out, err, code} = :erlang.binary_to_term(data)
        if out != "", do: IO.write(out)
        if err != "", do: IO.write(:stderr, err)
        System.halt(code)
    end
  '
