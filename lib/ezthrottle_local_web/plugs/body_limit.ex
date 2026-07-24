defmodule EzthrottleLocalWeb.Plugs.BodyLimit do
  @moduledoc """
  Rejects oversized request bodies with 413 before Plug.Parsers reads them,
  mirroring Aquifer's http.MaxBytesReader-driven behavior. Controlled by
  EZTHROTTLE_MAX_BODY_BYTES (0/unset = disabled, matching admission
  control's opt-in pattern).

  This checks Content-Length up front rather than counting bytes as the
  body streams in, so it only catches clients that send that header — a
  chunked request without Content-Length falls through to Plug.Parsers'
  own (larger, fixed) internal limit instead. Good enough parity for the
  common case without reimplementing a streaming byte-counter.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    limit = EzthrottleLocal.Admission.max_body_bytes()

    if limit > 0 do
      case get_req_header(conn, "content-length") do
        [len_str] ->
          case Integer.parse(len_str) do
            {len, _} when len > limit ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(
                413,
                Jason.encode!(%{error: "request body too large", limit_bytes: limit})
              )
              |> halt()

            _ ->
              conn
          end

        _ ->
          conn
      end
    else
      conn
    end
  end
end
