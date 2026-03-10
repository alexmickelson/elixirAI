FROM elixir:1.19.5-otp-28-alpine

RUN apk add --no-cache build-base git bash wget nodejs npm inotify-tools

WORKDIR /app

ENV USER="elixir"
RUN addgroup -g 1000 $USER && \
  adduser -D -u 1000 -G $USER $USER

RUN mkdir -p /app/_build && \
  chown -R elixir:elixir /app

USER elixir

RUN mix local.hex --force && \
  mix local.rebar --force
