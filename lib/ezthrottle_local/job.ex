defmodule EzthrottleLocal.Job do
  @moduledoc """
  Job struct representing an outbound API request to be queued and executed.
  The caller is responsible for authentication before submitting jobs.
  user_id is trusted as supplied.
  """

  @type status :: :queued | :completed | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          user_id: String.t(),
          idempotent_key: String.t(),
          idempotency_scope: String.t() | nil,
          max_retries: integer(),
          attempts: non_neg_integer(),
          url: String.t() | nil,
          pool_id: String.t() | nil,
          method: String.t(),
          headers: map(),
          body: String.t() | nil,
          webhook_url: String.t(),
          status: status(),
          created_at: integer(),
          execute_before: integer() | nil,
          origin_machine_id: String.t() | nil,
          origin_region: String.t() | nil,
          visited_regions: [String.t()],
          reroute_count: integer(),
          direct_only: boolean()
        }

  defstruct [
    :id,
    :user_id,
    :idempotent_key,
    :idempotency_scope,
    :url,
    :pool_id,
    :method,
    :headers,
    :body,
    :webhook_url,
    status: :queued,
    max_retries: 4,
    attempts: 0,
    created_at: nil,
    execute_before: nil,
    origin_machine_id: nil,
    origin_region: nil,
    visited_regions: [],
    reroute_count: 0,
    direct_only: false
  ]

  @doc """
  Build a Job from validated params. Returns {:ok, job} or {:error, reason}.
  Exactly one of "url" or "pool_id" must be set -- a job dispatches to a
  fixed URL or to a registered pool, never both.
  """
  def new(params) do
    url = blank_to_nil(Map.get(params, "url"))
    pool_id = blank_to_nil(Map.get(params, "pool_id"))

    with {:ok, user_id} <- require_field(params, "user_id"),
         :ok <- reject_nul(user_id),
         {:ok, scope} <- parse_idempotency_scope(Map.get(params, "idempotency_scope")),
         {:ok, max_retries} <- parse_max_retries(Map.get(params, "max_retries")),
         :ok <- require_exactly_one_of_url_or_pool_id(url, pool_id),
         {:ok, method} <- require_field(params, "method"),
         {:ok, webhook_url} <- require_field(params, "webhook_url"),
         {:ok, idempotent_key} <- require_field(params, "idempotent_key"),
         {:ok, execute_before} <- parse_execute_before(Map.get(params, "execute_before")) do
      {:ok,
       %__MODULE__{
         id: generate_id(),
         user_id: user_id,
         idempotent_key: idempotent_key,
         idempotency_scope: scope,
         max_retries: max_retries,
         url: url,
         pool_id: pool_id,
         method: String.upcase(method),
         headers: Map.get(params, "headers", %{}),
         body: Map.get(params, "body"),
         webhook_url: webhook_url,
         status: :queued,
         created_at: System.system_time(:millisecond),
         execute_before: execute_before,
         origin_machine_id: blank_to_nil(Map.get(params, "origin_machine_id")),
         origin_region: blank_to_nil(Map.get(params, "origin_region")),
         visited_regions: Map.get(params, "visited_regions", []),
         reroute_count: Map.get(params, "reroute_count", 0),
         direct_only: Map.get(params, "direct_only", false)
       }}
    end
  end

  @doc """
  "shared" dedups on idempotent_key alone, across every user_id, so concurrent
  callers asking for the same resource coalesce onto one upstream call. Off
  unless EZTHROTTLE_SHARED_IDEMPOTENCY_ENABLED=true.
  """
  def shared_idempotency_enabled?,
    do: System.get_env("EZTHROTTLE_SHARED_IDEMPOTENCY_ENABLED") == "true"

  defp parse_idempotency_scope(scope) when scope in [nil, "", "user"], do: {:ok, nil}

  defp parse_idempotency_scope("shared") do
    if shared_idempotency_enabled?(),
      do: {:ok, "shared"},
      else:
        {:error,
         ~s(idempotency_scope "shared" requires EZTHROTTLE_SHARED_IDEMPOTENCY_ENABLED=true)}
  end

  defp parse_idempotency_scope(_), do: {:error, ~s(idempotency_scope must be "user" or "shared")}

  # A NUL-free user_id is what keeps the shared hash ("shared\0" <> key) from
  # ever colliding with a per-user one (user_id <> ":" <> key).
  defp reject_nul(user_id) when is_binary(user_id) do
    if String.contains?(user_id, <<0>>),
      do: {:error, "user_id must not contain NUL characters"},
      else: :ok
  end

  defp reject_nul(_user_id), do: :ok

  @default_max_retries 4
  @max_allowed_retries 100
  # Bounds retry_until_complete when there is no execute_before: the same
  # 24h default the idempotency TTL uses for queued jobs.
  @default_retry_window_ms 86_400_000

  @doc """
  Retries for retryable failures (connection errors, 5xx, 408, 429): 4 by
  default, -1 to retry until the job succeeds (bounded by execute_before, or
  24h after submission). Mirrors Aquifer's max_retries / X-Aqueduct-Max-Retries.
  """
  def max_retries(%__MODULE__{} = job), do: Map.get(job, :max_retries, @default_max_retries)
  def attempts(%__MODULE__{} = job), do: Map.get(job, :attempts, 0)

  def retries_left?(job), do: max_retries(job) == -1 or attempts(job) < max_retries(job)

  def retry_deadline_ms(%__MODULE__{execute_before: before})
      when is_integer(before) and before > 0,
      do: before

  def retry_deadline_ms(%__MODULE__{created_at: created_at}),
    do: (created_at || System.system_time(:millisecond)) + @default_retry_window_ms

  defp parse_max_retries(nil), do: {:ok, @default_max_retries}

  defp parse_max_retries(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} -> parse_max_retries(n)
      _ -> {:error, max_retries_error()}
    end
  end

  defp parse_max_retries(n) when is_integer(n) and n >= -1 and n <= @max_allowed_retries,
    do: {:ok, n}

  defp parse_max_retries(_), do: {:error, max_retries_error()}

  defp max_retries_error,
    do: "max_retries must be -1 (retry until complete) or between 0 and 100"

  defp require_exactly_one_of_url_or_pool_id(nil, nil),
    do: {:error, "either url or pool_id is required"}

  defp require_exactly_one_of_url_or_pool_id(url, pool_id) when url != nil and pool_id != nil,
    do: {:error, "url and pool_id are mutually exclusive -- a job dispatches to one or the other"}

  defp require_exactly_one_of_url_or_pool_id(_url, _pool_id), do: :ok

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(val), do: val

  @doc """
  Extract the API key from job headers to determine which AccountQueue to route to.
  Checks Authorization, x-api-key, api-key headers in order.
  Returns a hashed queue key scoped to the user_id, or a hashed anonymous key.
  """
  def queue_key(%__MODULE__{idempotency_scope: "shared", idempotent_key: key}) do
    # Shared-scope jobs get one queue per shared key instead of per user, so
    # every caller for that key reaches the same cluster-wide queue owner,
    # whose store dedups them. Per-user jobs are unaffected.
    :crypto.hash(:sha256, "shared" <> <<0>> <> key) |> Base.encode16(case: :lower)
  end

  def queue_key(%__MODULE__{user_id: user_id, headers: headers}) do
    api_key =
      headers["Authorization"] ||
        headers["authorization"] ||
        headers["x-api-key"] ||
        headers["X-Api-Key"] ||
        headers["api-key"]

    raw =
      case api_key do
        nil -> "anonymous:#{user_id}"
        key -> "#{user_id}:#{key}"
      end

    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  @doc """
  Builds a Job representing a webhook delivery attempt itself, for
  AccountQueueRegistry.enqueue_webhook/4 to push webhook delivery through
  the same account-queue pacing as forward dispatch instead of firing
  immediately with a fixed retry schedule. webhook_url is "" on the
  resulting job (see webhook_delivery_job?/1), never nil, so it always
  matches the same check regardless of how the field ends up compared.

  original_job_id scopes the idempotent key so a given job's webhook is
  enqueued at most once even if this is somehow called twice for it.
  """
  def new_webhook_delivery(original_job_id, user_id, webhook_url, payload) do
    %__MODULE__{
      id: generate_id(),
      user_id: user_id,
      idempotent_key: "webhook:" <> original_job_id,
      url: webhook_url,
      pool_id: nil,
      method: "POST",
      headers: %{"Content-Type" => "application/json"},
      body: Jason.encode!(payload),
      webhook_url: "",
      status: :queued,
      created_at: System.system_time(:millisecond)
    }
  end

  @doc """
  Reports whether this job represents a webhook delivery attempt itself
  (see new_webhook_delivery/4), as opposed to a regular user-submitted
  job. A regular job always has a non-empty webhook_url -- new/1 requires
  one -- so an empty webhook_url is a safe, already-enforced signal rather
  than a separate field: it's what AccountQueue checks to avoid
  enqueueing a webhook-about-a-webhook, and what make_request checks to
  decide whether to L8-sign the outbound request.
  """
  def webhook_delivery_job?(%__MODULE__{webhook_url: url}), do: url in [nil, ""]

  @doc """
  Rebuilds a job read back from Mnesia as the current struct. Records written
  by older versions lack newer fields (execute_before, for one), and pattern
  matches on the struct crash on them; missing fields get their defaults.
  """
  def upgrade(%__MODULE__{} = job), do: struct(__MODULE__, Map.from_struct(job))
  def upgrade(other), do: other

  def execution_expired?(%__MODULE__{execute_before: nil}), do: false
  def execution_expired?(%__MODULE__{execute_before: 0}), do: false

  def execution_expired?(%__MODULE__{execute_before: execute_before})
      when is_integer(execute_before),
      do: System.system_time(:millisecond) >= execute_before

  defp parse_execute_before(nil), do: {:ok, nil}
  defp parse_execute_before(0), do: {:ok, nil}
  defp parse_execute_before(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_execute_before(_value),
    do: {:error, "execute_before must be a positive Unix timestamp in milliseconds"}

  defp require_field(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "#{key} is required"}
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end
end
