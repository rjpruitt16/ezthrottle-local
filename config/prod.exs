# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

import Config

# Do not print debug messages in production
config :logger, level: :info

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.
