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
          url: String.t() | nil,
          pool_id: String.t() | nil,
          method: String.t(),
          headers: map(),
          body: String.t() | nil,
          webhook_url: String.t(),
          status: status(),
          created_at: integer()
        }

  defstruct [
    :id,
    :user_id,
    :idempotent_key,
    :url,
    :pool_id,
    :method,
    :headers,
    :body,
    :webhook_url,
    status: :queued,
    created_at: nil
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
         :ok <- require_exactly_one_of_url_or_pool_id(url, pool_id),
         {:ok, method} <- require_field(params, "method"),
         {:ok, webhook_url} <- require_field(params, "webhook_url"),
         {:ok, idempotent_key} <- require_field(params, "idempotent_key") do
      {:ok,
       %__MODULE__{
         id: generate_id(),
         user_id: user_id,
         idempotent_key: idempotent_key,
         url: url,
         pool_id: pool_id,
         method: String.upcase(method),
         headers: Map.get(params, "headers", %{}),
         body: Map.get(params, "body"),
         webhook_url: webhook_url,
         status: :queued,
         created_at: System.system_time(:millisecond)
       }}
    end
  end

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
