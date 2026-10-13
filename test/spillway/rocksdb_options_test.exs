# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.RocksdbOptionsTest do
  @moduledoc """
  Every RocksDB table runs with the small write buffers from
  config :mnesia_rocksdb, :rocksdb_opts. With RocksDB's 64MB default, each
  table held up to about 190MB of buffers outside the BEAM, and in soak run
  3e that kept admission refusing every job. RocksDB writes the options
  each column family was opened with to an OPTIONS file in the store.
  Runs with SPILLWAY_STORAGE=rocksdb.
  """

  use ExUnit.Case, async: false

  alias Spillway.IdempotentStore

  @tag :rocksdb
  test "every column family is opened with the configured write buffer" do
    if IdempotentStore.storage() != "rocksdb", do: :ok, else: check_options()
  end

  defp check_options do
    expected = Application.fetch_env!(:mnesia_rocksdb, :rocksdb_opts)[:write_buffer_size]

    [options | _] =
      Path.join([to_string(:mnesia.system_info(:directory)), "**", "OPTIONS-*"])
      |> Path.wildcard()
      |> Enum.sort_by(&File.stat!(&1, time: :posix).mtime, :desc)

    sections =
      options
      |> File.read!()
      |> String.split(~r/^\[CFOptions /m)
      |> tl()

    assert length(sections) >= 6

    for section <- sections do
      [name | _] = String.split(section, "\n", parts: 2)
      assert section =~ ~r/^\s*write_buffer_size=#{expected}$/m, "#{name} uses another buffer"
    end
  end
end
