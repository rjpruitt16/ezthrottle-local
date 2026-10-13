# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# RocksDB tables (SPILLWAY_STORAGE=rocksdb): callers read and write RocksDB
# directly. The default, legacy, sends every read and write through one
# process per table; in soak run 3c those queued over 10,000 writes and the
# node ran out of memory.
config :mnesia_rocksdb, default_access_type: :direct

# Small write buffers for every RocksDB table. Each table also keeps up to
# max_write_buffer_number * write_buffer_size of flushed buffers for
# transaction conflict checks, so with RocksDB's default 64MB buffers six
# tables held about 700MB outside the BEAM. In soak run 3e that kept
# resident memory over SPILLWAY_MEMORY_LIMIT_MB, and admission refused
# every job for hours. 8MB keeps it near 25MB a table.
config :mnesia_rocksdb,
  rocksdb_opts: [write_buffer_size: 8 * 1024 * 1024, max_write_buffer_number: 2]

config :spillway,
  generators: [timestamp_type: :utc_datetime],
  metrics_adapter: Spillway.Metrics.Noop

config :syn,
  scopes: [:ezthrottle_account_queues, :ezthrottle_job_stores],
  # Keeps both processes alive on a registry conflict (netsplit heal) so an
  # account queue that loses its name still finishes the jobs it holds.
  event_handler: Spillway.SynEventHandler

# Configures the endpoint
config :spillway, SpillwayWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: SpillwayWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Spillway.PubSub,
  live_view: [signing_salt: "spScA2A9"]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
