defmodule EzthrottleLocal.PoolMember do
  @moduledoc """
  One registered target within a pool — the Elixir port of Aquifer's
  PoolMember (pool.go), ported after the Go implementation was built and
  tested first. See EzthrottleLocal.Pool for the selection/reputation
  logic that operates on this struct.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          address: String.t(),
          declared_rps: float(),
          heartbeat_interval_ms: non_neg_integer(),
          last_heartbeat: integer(),
          reputation: float(),
          virtual_position: float(),
          floor_since: integer() | nil
        }

  defstruct [
    :id,
    :address,
    :declared_rps,
    :heartbeat_interval_ms,
    :last_heartbeat,
    reputation: 1.0,
    virtual_position: 0.0,
    floor_since: nil
  ]

  @doc """
  Effective share of dispatch: declared capacity scaled by how much the
  member is currently trusted. A member reporting a high rate but failing
  consistently still gets throttled down by this, even if its
  last-reported capacity was optimistic.
  """
  @spec weight(t()) :: float()
  def weight(%__MODULE__{declared_rps: rps, reputation: rep}) do
    w = rps * rep
    if w <= 0, do: 0.001, else: w
  end
end
