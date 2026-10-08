defmodule EzthrottleLocalWeb.Plugs.InFlightLimit do
  @moduledoc """
  Sheds new submissions with 429 + Retry-After once too many are already in
  progress. Without this, past its ceiling a node collapsed instead of
  shedding: requests piled up waiting to be admitted, holding a connection and
  a process each, until clients timed out and retried. Admission control
  looks at queue backlog and never saw them.

  Counts POST /jobs and POST /proxy, from arrival until the response starts.
  A /proxy fallback releases its slot when it switches to streaming (its
  response starts then), so long streams don't hold one.

  EZTHROTTLE_MAX_IN_FLIGHT_REQUESTS sets the cap (default 512); 0 disables it.
  """

  import Plug.Conn

  @default_limit 512
  @held :in_flight_limit_held

  @doc "Creates the shared counter. Called once at application start."
  def setup do
    :persistent_term.put({__MODULE__, :ref}, :atomics.new(1, signed: true))
  end

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", path_info: [route]} = conn, _opts)
      when route in ["jobs", "proxy"] do
    case {limit(), ref()} do
      {0, _} -> conn
      {_, nil} -> conn
      {limit, ref} -> acquire(conn, ref, limit)
    end
  end

  def call(conn, _opts), do: conn

  @doc "Requests currently counted (for tests and /health)."
  def in_flight do
    case ref() do
      nil -> 0
      ref -> :atomics.get(ref, 1)
    end
  end

  defp acquire(conn, ref, limit) do
    # A slot still marked held in this process belongs to an earlier request
    # on the same connection that died before responding; give it back.
    if Process.get(@held), do: release(ref)

    if :atomics.add_get(ref, 1, 1) > limit do
      :atomics.sub(ref, 1, 1)

      conn
      |> put_resp_header(
        "retry-after",
        to_string(EzthrottleLocal.Admission.base_retry_after_seconds())
      )
      |> put_resp_content_type("application/json")
      |> send_resp(
        429,
        Jason.encode!(%{
          error: "admission rejected: in_flight (limit #{limit})",
          limit_reason: "in_flight",
          limit: limit,
          current: limit
        })
      )
      |> halt()
    else
      Process.put(@held, true)
      register_before_send(conn, fn conn -> release(ref) && conn end)
    end
  end

  defp release(ref) do
    if Process.delete(@held), do: :atomics.sub(ref, 1, 1)
    true
  end

  defp ref, do: :persistent_term.get({__MODULE__, :ref}, nil)

  defp limit do
    case System.get_env("EZTHROTTLE_MAX_IN_FLIGHT_REQUESTS") do
      nil ->
        @default_limit

      val ->
        case Integer.parse(val) do
          {n, _} when n >= 0 -> n
          _ -> @default_limit
        end
    end
  end
end
