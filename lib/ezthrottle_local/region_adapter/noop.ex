defmodule EzthrottleLocal.RegionAdapter.Noop do
  @moduledoc """
  Default RegionAdapter: no known regions, cross-region redirect never
  triggers. This is what "the feature is off" looks like -- Redirect checks
  live_regions() being empty as its gate for even considering redirect, so a
  deployment that never configures :region_adapter sees zero behavior
  change from this feature existing in the codebase. Mirrors
  EzthrottleLocal.Metrics.Noop / Aquifer's NoopRegionAdapter.
  """

  @behaviour EzthrottleLocal.RegionAdapter

  @impl true
  def live_regions, do: []

  @impl true
  def self_region, do: nil
end
