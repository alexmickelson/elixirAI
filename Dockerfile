# ---- Build stage ----
FROM elixir:1.19.5-otp-28-alpine AS build

RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.deploy
RUN mix release

# ---- Runtime stage ----
FROM elixir:1.19.5-otp-28-alpine AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs docker-cli

WORKDIR /app

COPY --from=build /app/_build/prod/rel/elixir_ai ./
RUN touch .env

ENV PHX_SERVER=true

EXPOSE 4000

CMD ["bin/elixir_ai", "start"]
