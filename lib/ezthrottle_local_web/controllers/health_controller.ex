defmodule EzthrottleLocalWeb.HealthController do
  use EzthrottleLocalWeb, :controller

  def index(conn, _params) do
    json(conn, %{
      status: "ok",
      l8_protocol: "0.1",
      l8_public_key: EzthrottleLocal.L8.pub_b64(),
      admission: EzthrottleLocal.Admission.snapshot()
    })
  end
end
