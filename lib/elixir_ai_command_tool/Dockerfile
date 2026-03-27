FROM elixir:1.18-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  socat \
  coreutils \
  grep \
  curl \
  git \
  ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

# Copy the entire elixir project (command tool modules are compiled as part of the app)
COPY mix.exs mix.lock ./
COPY config config
COPY lib lib
COPY deps deps

RUN mix deps.get && MIX_ENV=tools_api mix compile

# Install shims — only runner.sh and the generator are checked in;
# symlinks are created at build time by generate_shims.sh
COPY lib/elixir_ai_command_tool/shims/runner.sh /app/shims/runner.sh
COPY lib/elixir_ai_command_tool/shims/generate_shims.sh /app/shims/generate_shims.sh
RUN chmod +x /app/shims/runner.sh /app/shims/generate_shims.sh \
  && /app/shims/generate_shims.sh

# PATH: shims first, then normal system paths
ENV PATH="/app/shims:/usr/local/bin:/usr/bin:/bin"
ENV COMMAND_TOOL_PORT=4001
ENV MIX_ENV=tools_api

COPY lib/elixir_ai_command_tool/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 4001

ENTRYPOINT ["/app/entrypoint.sh"]
