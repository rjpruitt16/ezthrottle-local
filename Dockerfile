FROM elixir:1.17-alpine AS build

RUN apk add --no-cache build-base git

WORKDIR /app

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv

RUN mix compile
RUN mix release

FROM alpine:3.22 AS app

RUN apk add --no-cache libstdc++ openssl ncurses-libs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/ezthrottle_local ./

ENV PHX_HOST=localhost
ENV PORT=4000
ENV PHX_SERVER=true

EXPOSE 4000

CMD ["bin/ezthrottle_local", "start"]
