defmodule EzthrottleLocalWeb.HealthController do
  use EzthrottleLocalWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
