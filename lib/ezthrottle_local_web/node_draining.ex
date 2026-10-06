defmodule EzthrottleLocalWeb.NodeDraining do
  @moduledoc """
  503 response for a draining node, header-for-header with Aquifer's
  writeNodeDraining. Also usable as a plug to reject new work while draining.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if EzthrottleLocal.Lifecycle.draining?(), do: reject(conn), else: conn
  end

  def reject(conn) do
    conn
    |> put_resp_header(
      "retry-after",
      Integer.to_string(EzthrottleLocal.Lifecycle.retry_after_seconds())
    )
    |> put_resp_header("x-aqueduct-node-state", "draining")
    |> put_resp_header("x-ezthrottle-node-state", "draining")
    |> put_resp_header("connection", "close")
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "node is draining"}))
    |> halt()
  end
end
