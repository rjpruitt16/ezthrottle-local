defmodule EzthrottleLocal.L8.Schemas do
  @moduledoc """
  L8 0.2 request schemas. An upstream publishes JSON Schemas per route
  ("POST /path") in its /.well-known/l8; job bodies are checked before
  dispatch and rejected with 422 on mismatch. A changed X-Aqueduct-Schema-Hash
  response header drops the cached schemas and the domain's L8 trust.
  Mirrors Aquifer's l8_schema.go.

  Only started when EZTHROTTLE_L8_SCHEMA_VALIDATION=true. When it isn't
  running, validate/3 and observe_hash/2 are no-ops. Anything that fails to
  fetch or compile degrades open, and external $refs are never fetched
  (JSV only resolves its embedded meta-schemas unless given a resolver).
  """
  use GenServer
  require Logger

  @table :l8_schemas
  @ttl_ms 10 * 60 * 1_000
  @negative_ttl_ms 60 * 1_000
  # An upstream whose header disagrees with its own metadata would otherwise
  # force a refetch per response.
  @default_min_refetch_ms 10_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def enabled?, do: System.get_env("EZTHROTTLE_L8_SCHEMA_VALIDATION") == "true"

  @doc "Returns :ok or {:error, %{route, schema_hash, detail}}."
  def validate(url, method, body) when is_binary(url) do
    with true <- running?(),
         %{routes: routes, hash: hash} <- entry(EzthrottleLocal.L8.domain_from_url(url)),
         route = route_key(method, url),
         {:ok, root} <- Map.fetch(routes, route) do
      check(root, body, route, hash)
    else
      _ -> :ok
    end
  end

  def validate(_url, _method, _body), do: :ok

  def observe_hash(_url, nil), do: :ok
  def observe_hash(_url, ""), do: :ok

  def observe_hash(url, hash) do
    if running?() do
      domain = EzthrottleLocal.L8.domain_from_url(url)
      now = System.monotonic_time(:millisecond)

      case :ets.lookup(@table, domain) do
        [{^domain, %{hash: cached, fetched_at: fetched_at}}] when cached != hash ->
          if now - fetched_at >= min_refetch_ms() do
            :ets.delete(@table, domain)
            EzthrottleLocal.L8.invalidate(url)

            Logger.info(
              "[L8] #{domain} advertised schema hash #{hash}; refetching metadata and re-handshaking"
            )
          end

        _ ->
          :ok
      end
    end

    :ok
  end

  # ---- GenServer ----

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{inflight: %{}}}
  end

  # One fetch per domain at a time: concurrent callers for the same domain
  # wait on the in-flight task instead of all hitting /.well-known/l8.
  @impl true
  def handle_call({:load, domain}, from, state) do
    case fresh(domain) do
      %{} = entry ->
        {:reply, entry, state}

      nil ->
        case Map.fetch(state.inflight, domain) do
          {:ok, waiters} ->
            {:noreply, put_in(state.inflight[domain], [from | waiters])}

          :error ->
            parent = self()
            spawn(fn -> send(parent, {:loaded, domain, load(domain)}) end)
            {:noreply, put_in(state.inflight[domain], [from])}
        end
    end
  end

  @impl true
  def handle_info({:loaded, domain, entry}, state) do
    :ets.insert(@table, {domain, entry})
    {waiters, inflight} = Map.pop(state.inflight, domain, [])
    Enum.each(waiters, &GenServer.reply(&1, entry))
    {:noreply, %{state | inflight: inflight}}
  end

  # ---- private ----

  defp running?, do: enabled?() and Process.whereis(__MODULE__) != nil

  defp entry(domain) do
    case fresh(domain) do
      nil -> GenServer.call(__MODULE__, {:load, domain}, 15_000)
      entry -> entry
    end
  catch
    :exit, _ -> nil
  end

  defp fresh(domain) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, domain) do
      [{^domain, %{expires_at: expires_at} = entry}] when expires_at > now -> entry
      _ -> nil
    end
  end

  defp load(domain) do
    now = System.monotonic_time(:millisecond)
    negative = %{hash: nil, routes: %{}, fetched_at: now, expires_at: now + @negative_ttl_ms}

    with {:ok, %{"request_schemas" => raw} = meta} when is_map(raw) and map_size(raw) > 0 <-
           EzthrottleLocal.L8.fetch_meta(domain),
         {:hash, hash} when is_binary(hash) and hash != "" <-
           {:hash, Map.get(meta, "schema_hash")},
         {:ok, routes} <- compile(raw) do
      %{hash: hash, routes: routes, fetched_at: now, expires_at: now + @ttl_ms}
    else
      {:hash, _} ->
        Logger.warning(
          "[L8] #{domain} advertises request_schemas without schema_hash; ignoring them"
        )

        negative

      {:error, reason} ->
        Logger.warning("[L8] #{domain} request_schemas did not compile: #{reason}")
        negative

      _ ->
        negative
    end
  end

  defp compile(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {route, schema}, {:ok, acc} ->
      with {:ok, key} <- normalize_route(route),
           {:ok, root} <- JSV.build(schema) do
        {:cont, {:ok, Map.put(acc, key, root)}}
      else
        :error -> {:halt, {:error, "route #{inspect(route)} must look like \"POST /path\""}}
        {:error, reason} -> {:halt, {:error, "#{route}: #{describe(reason)}"}}
      end
    end)
  end

  defp describe(%JSV.BuildError{reason: reason}), do: inspect(reason, limit: 10)
  defp describe(reason), do: inspect(reason)

  defp check(root, body, route, hash) do
    case Jason.decode(body || "") do
      {:ok, data} ->
        case JSV.validate(data, root) do
          {:ok, _} -> :ok
          {:error, err} -> mismatch(route, hash, Exception.message(err))
        end

      {:error, _} ->
        mismatch(route, hash, "body is not valid JSON")
    end
  end

  defp mismatch(route, hash, detail),
    do: {:error, %{route: route, schema_hash: hash, detail: detail}}

  defp normalize_route(route) when is_binary(route) do
    case String.split(String.trim(route), " ", parts: 2) do
      [method, "/" <> _ = path] when method != "" ->
        {:ok, String.upcase(method) <> " " <> String.trim(path)}

      _ ->
        :error
    end
  end

  defp normalize_route(_), do: :error

  defp route_key(method, url) do
    path =
      case URI.parse(url).path do
        nil -> "/"
        "" -> "/"
        path -> path
      end

    String.upcase(method) <> " " <> path
  end

  defp min_refetch_ms,
    do: Application.get_env(:ezthrottle_local, :l8_schema_min_refetch_ms, @default_min_refetch_ms)
end
