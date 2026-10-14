FROM elixir:1.17-alpine AS build

# cmake, bash and linux-headers build RocksDB (the rocksdb dependency)
# from source; there's no prebuilt library for Alpine.
RUN apk add --no-cache build-base git cmake bash linux-headers snappy-dev
# RocksDB and its bundled Snappy use uint64_t without including <cstdint>,
# which GCC 15 (Alpine's) no longer pulls in on its own. Include it in every
# C++ file, and link Alpine's Snappy rather than building the bundled copy.
ENV ERLANG_ROCKSDB_OPTS="-DWITH_SNAPPY=ON -DWITH_BUNDLE_LZ4=ON" \
    CXXFLAGS="-include cstdint"

WORKDIR /app

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY lib lib
COPY priv priv
COPY rel rel

RUN mix compile
RUN mix release

FROM alpine:3.22 AS app

RUN apk add --no-cache libstdc++ openssl ncurses-libs snappy

WORKDIR /app

COPY --from=build /app/_build/prod/rel/spillway ./

ENV PHX_HOST=localhost
ENV PORT=4000
ENV PHX_SERVER=true

EXPOSE 4000

CMD ["bin/spillway", "start"]
