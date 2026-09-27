defmodule EzthrottleLocal.Cluster do
  @moduledoc """
  Region-local BEAM discovery and Syn naming for durable queue ownership.

  Discovery is disabled when `DNS_CLUSTER_QUERY` is unset. Syn still runs in
  that case, so the same ownership path is used in standalone deployments.
  """

  @account_queue_scope :ezthrottle_account_queues
  @job_store_scope :ezthrottle_job_stores

  def account_queue_scope, do: @account_queue_scope
  def job_store_scope, do: @job_store_scope

  def topologies do
    case Application.get_env(:ezthrottle_local, :dns_cluster_query) do
      query when is_binary(query) and query != "" ->
        [
          ezthrottle_dns: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: polling_interval_ms(),
              query: query,
              node_basename: node_basename()
            ]
          ]
        ]

      _ ->
        []
    end
  end

  def account_queue_name(upstream, queue_key),
    do: {:account_queue, upstream, queue_key}

  def account_queue_via(upstream, queue_key),
    do: {:via, :syn, {@account_queue_scope, account_queue_name(upstream, queue_key)}}

  def lookup_account_queue(upstream, queue_key) do
    case :syn.lookup(@account_queue_scope, account_queue_name(upstream, queue_key)) do
      {pid, _metadata} -> pid
      :undefined -> nil
    end
  end

  def join_upstream(upstream, pid) do
    :syn.join(@account_queue_scope, {:upstream, upstream}, pid)
  end

  def account_queues_for_upstream(upstream) do
    @account_queue_scope
    |> :syn.members({:upstream, upstream})
    |> Enum.map(fn {pid, _metadata} -> pid end)
  end

  def join_url_actor(upstream, pid) do
    :syn.join(@account_queue_scope, {:url_actors, upstream}, pid)
  end

  def url_actors_for_upstream(upstream) do
    @account_queue_scope
    |> :syn.members({:url_actors, upstream})
    |> Enum.map(fn {pid, _metadata} -> pid end)
  end

  def lookup_job_store(job_id) do
    case :syn.lookup(@job_store_scope, job_id) do
      {pid, _metadata} -> pid
      :undefined -> nil
    end
  end

  defp node_basename do
    System.get_env("EZTHROTTLE_CLUSTER_NODE_BASENAME") ||
      node() |> Atom.to_string() |> String.split("@", parts: 2) |> hd()
  end

  defp polling_interval_ms do
    case Integer.parse(System.get_env("EZTHROTTLE_CLUSTER_POLL_INTERVAL_MS", "5000")) do
      {value, ""} when value > 0 -> value
      _ -> 5_000
    end
  end
end
