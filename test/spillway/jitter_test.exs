# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.JitterTest do
  use ExUnit.Case, async: true

  alias Spillway.Jitter

  test "add_ms/2 adds a small positive delay" do
    base = 1_000
    jittered = Jitter.add_ms(base)

    assert jittered >= base
    assert jittered <= 1_100
  end

  test "add_ms/2 leaves non-positive values alone" do
    assert Jitter.add_ms(0) == 0
    assert Jitter.add_ms(-1_000) == -1_000
  end
end
