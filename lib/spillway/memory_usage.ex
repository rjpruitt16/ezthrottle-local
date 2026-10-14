# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule Spillway.MemoryUsage do
  @moduledoc """
  The process's resident memory, which is what the kernel's OOM killer
  compares against the machine's limit. The VM's own count
  (`:erlang.memory(:total)`) leaves out allocator overhead and
  fragmentation; the soak test measured resident size at 1.14x to 1.4x
  of it, so a limit checked against the VM count let the kernel kill
  Spillway before admission refused a job. Falls back to the VM count
  where /proc isn't available.
  """

  @doc "Resident memory in MB."
  def mb do
    case rss_bytes() do
      {:ok, bytes} -> div(bytes, 1_048_576)
      :error -> vm_mb()
    end
  end

  @doc "The VM's own memory count in MB. It drops as soon as data is freed."
  def vm_mb, do: div(:erlang.memory(:total), 1_048_576)

  defp rss_bytes do
    # Raw, so it doesn't queue behind other callers of OTP's :file_server.
    with {:ok, status} <- :file.read_file(~c"/proc/self/status", [:raw]),
         [_, kb] <- Regex.run(~r/^VmRSS:\s+(\d+) kB/m, status) do
      {:ok, String.to_integer(kb) * 1024}
    else
      _ -> :error
    end
  end
end
