# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :spillway, SpillwayWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "HR2qlZsS3F111UZvJNY2Q6bmWTLPp5NnU5jqZq8syib+ObOflc5K8Ubu1QHGQUMJ",
  server: false

# Fresh directory per test run — Mnesia has no per-test-case reset the way
# a Go test can just create a new t.TempDir() SQLite file, so isolation
# here is at the whole-suite level. Tests should use unique idempotent
# keys/user_ids the way Aquifer's own tests do, rather than relying on a
# clean slate between individual test cases.
config :spillway, :mnesia_dir, "tmp/mnesia_test_#{System.system_time(:millisecond)}"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# WebSocket transcript budget: tests run the check themselves.
config :spillway, :websocket_budget_interval_ms, 0
