defmodule EzthrottleLocal.RegionAdapter do
  @moduledoc """
  Pluggable region-liveness adapter entrypoint, backing /proxy's cross-region
  redirect (EzthrottleLocal.Redirect). Mirrors EzthrottleLocal.Metrics's
  adapter pattern exactly: a small behaviour, a no-op default, the deployer
  plugs in a real implementation. Off unless explicitly configured
  (EZTHROTTLE_FLY_REGIONS) -- matches every other opt-in feature in this
  codebase, same convention Aquifer's RegionAdapter/region_adapter.go uses.

  Configure `:region_adapter` to route to a real implementation
  (EzthrottleLocal.RegionAdapter.Fly).
  """

  @callback live_regions() :: [String.t()]
  @callback self_region() :: String.t() | nil

  def live_regions, do: call(:live_regions, [])
  def self_region, do: call(:self_region, [])

  defp call(event, args) do
    adapter =
      Application.get_env(:ezthrottle_local, :region_adapter, EzthrottleLocal.RegionAdapter.Noop)

    apply(adapter, event, args)
  rescue
    _ -> default(event)
  end

  defp default(:live_regions), do: []
  defp default(:self_region), do: nil
end
