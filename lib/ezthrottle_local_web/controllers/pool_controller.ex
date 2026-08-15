defmodule EzthrottleLocalWeb.PoolController do
  use EzthrottleLocalWeb, :controller

  alias EzthrottleLocal.PoolRegistry

  @doc """
  Handles both initial registration and heartbeat refresh for a pool
  member -- the same request shape serves both, per the API design:
  re-calling this resets the member's liveness TTL and updates its
  declared capacity.
  """
  def register_member(conn, %{"pool_id" => pool_id} = params) do
    with {:ok, member_id} <- require_field(params, "member_id"),
         {:ok, address} <- require_field(params, "address"),
         {:ok, capacity_rps} <- require_positive_number(params, "capacity_rps") do
      heartbeat_interval_seconds = Map.get(params, "heartbeat_interval_seconds", 30)
      heartbeat_interval_ms = trunc(heartbeat_interval_seconds * 1_000)

      :ok =
        PoolRegistry.register(
          pool_id,
          member_id,
          address,
          capacity_rps * 1.0,
          heartbeat_interval_ms
        )

      json(conn, %{status: "registered"})
    else
      {:error, reason} ->
        conn |> put_status(:bad_request) |> json(%{error: reason})
    end
  end

  defp require_field(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "#{key} is required"}
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp require_positive_number(params, key) do
    case Map.get(params, key) do
      val when is_number(val) and val > 0 -> {:ok, val}
      _ -> {:error, "#{key} must be a number greater than 0"}
    end
  end
end
