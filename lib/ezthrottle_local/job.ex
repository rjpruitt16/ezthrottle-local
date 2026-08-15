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
