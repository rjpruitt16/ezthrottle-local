# Copyright 2026 Rahmi Pruitt
# SPDX-License-Identifier: Apache-2.0

defmodule SpillwayWeb.Plugs.Fullness do
  @moduledoc """
  Puts `x-aqueduct-fullness` (0-100, see Spillway.Admission.fullness/0) on
  every response, including the 429s and 503s this node sheds with, so
  whatever is in front of it can decide when to stop sending it new work.
  Runs ahead of InFlightLimit for exactly that reason.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    put_resp_header(conn, "x-aqueduct-fullness", Integer.to_string(Spillway.Admission.fullness()))
  end
end
