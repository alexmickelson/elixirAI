#!/usr/bin/env bash
set -e

echo "Starting CommandTool daemon..."

# Start the application — tools_api env boots only the CommandTool supervisor
elixir --no-halt -S mix run --no-compile &
DAEMON_PID=$!

# Wait for the HTTP server to be ready
echo "Waiting for HTTP server on port ${COMMAND_TOOL_PORT:-4001}..."
for i in $(seq 1 30); do
  if curl -sf "http://localhost:${COMMAND_TOOL_PORT:-4001}/api/execute" -X POST \
    -H "Content-Type: application/json" \
    -d '{"command":"echo","args":["ready"]}' > /dev/null 2>&1; then
    echo "CommandTool daemon ready."
    break
  fi
  sleep 1
done

# Keep the container alive, forwarding signals to the daemon
wait $DAEMON_PID
