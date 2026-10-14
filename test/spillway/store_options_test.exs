# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.StoreOptionsTest do
  @moduledoc """
  Every column family runs with small write buffers. With RocksDB's 64MB
  default, the old Mnesia-backed store held about 700MB of buffers outside
  the BEAM, and in soak run 3e that kept admission refusing every job.
  RocksDB writes the options it opened with to an OPTIONS file in the store.
  """

  use ExUnit.Case, async: false

  test "every column family is opened with 8MB write buffers" do
    [options | _] =
      Path.join(Spillway.Store.dir(), "OPTIONS-*")
      |> Path.wildcard()
      |> Enum.sort_by(&File.stat!(&1, time: :posix).mtime, :desc)

    text = File.read!(options)
    sections = text |> String.split(~r/^\[CFOptions /m) |> tl()

    # default plus the nine named column families
    assert length(sections) == 10

    for section <- sections do
      [name | _] = String.split(section, "\n", parts: 2)
      assert section =~ ~r/^\s*write_buffer_size=8388608$/m, "#{name} uses another buffer"
      assert section =~ ~r/^\s*max_write_buffer_number=2$/m, "#{name} keeps more buffers"
    end

    assert text =~ ~r/^\s*keep_log_file_num=5$/m

    tables = text |> String.split(~r/^\[TableOptions\/BlockBasedTable /m) |> tl()
    assert length(tables) == 10

    for table <- tables do
      [name | _] = String.split(table, "\n", parts: 2)
      assert table =~ ~r/^\s*filter_policy=bloomfilter:10:/m, "#{name} has no bloom filter"
    end
  end

  test "reads go through a shared cache of SPILLWAY_STORE_CACHE_MB" do
    expected = Integer.to_string(Spillway.Store.cache_mb() * 1024 * 1024)

    for cf <- [:jobs, :keys, :results] do
      assert Spillway.Store.property(cf, "rocksdb.block-cache-capacity") == expected
    end
  end
end
