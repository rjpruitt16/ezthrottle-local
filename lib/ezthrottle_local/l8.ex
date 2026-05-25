defmodule EzthrottleLocal.L8 do
  @moduledoc false
  use GenServer
  require Logger

  @key_path ".l8-key"
  @trust_dir "l8-trust"
  @nonce_ttl_ms 300_000
  @spec_url "https://rjpruitt16.github.io/l8-protocol/spec.json"

  # ---- Public API -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def pub_b64, do: :persistent_term.get(:l8_pub_b64)

  def meta(_host) do
    %{
      "protocol_version"     => "0.1",
      "service_name"         => "ezthrottle-local",
      "public_key"           => pub_b64(),
      "challenge_endpoint"   => "/l8/challenge",
      "supported_algorithms" => ["ed25519"],
      "capabilities"         => ["signed_payloads"],
      "spec_url"             => @spec_url
    }
  end

  def handle_challenge(params) do
    GenServer.call(__MODULE__, {:handle_challenge, params})
  end

  def ensure_trust(url) do
    domain = domain_from_url(url)
    if ets_trusted?(domain) do
      :ok
    else
      run_handshake(domain)
    end
  end

  def is_trusted?(url), do: ets_trusted?(domain_from_url(url))

  def sign_headers(body) when is_binary(body) do
    priv = :persistent_term.get(:l8_priv_key)
    pub  = :persistent_term.get(:l8_pub_key)
    delivery_id = random_uuid()
    timestamp   = Integer.to_string(System.os_time(:second))
    body_hash   = :crypto.hash(:sha256, body) |> Base.encode64()
    message     = "#{delivery_id}.#{timestamp}.#{body_hash}"
    sig         = :crypto.sign(:eddsa, :none, message, [priv, :ed25519]) |> Base.encode64()
    key_id      = binary_part(pub, 0, 8) |> Base.encode64()

    %{
      "X-L8-Delivery-Id" => delivery_id,
      "X-L8-Timestamp"   => timestamp,
      "X-L8-Key-Id"      => key_id,
      "X-L8-Signature"   => sig
    }
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts) do
    {priv, pub} = load_or_generate_key()
    pub_b64 = Base.encode64(pub)
    :persistent_term.put(:l8_priv_key, priv)
    :persistent_term.put(:l8_pub_key, pub)
    :persistent_term.put(:l8_pub_b64, pub_b64)
    :ets.new(:l8_trust, [:named_table, :public, read_concurrency: true])
    load_trust_from_disk()
    Process.send_after(self(), :cleanup_nonces, @nonce_ttl_ms)
    {:ok, %{nonces: %{}}}
  end

  @impl true
  def handle_call({:handle_challenge, params}, _from, state) do
    case do_handle_challenge(params, state) do
      {:ok, response, new_state} -> {:reply, {:ok, response}, new_state}
      {:error, reason}           -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:store_trust, domain, pub_b64, validated_at}, _from, state) do
    pub_bytes = Base.decode64!(pub_b64)
    :ets.insert(:l8_trust, {domain, pub_bytes, pub_b64, validated_at})
    write_trust_file(domain, pub_b64, validated_at)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup_nonces, state) do
    now    = System.monotonic_time(:millisecond)
    nonces = Map.filter(state.nonces, fn {_k, exp} -> exp > now end)
    Process.send_after(self(), :cleanup_nonces, @nonce_ttl_ms)
    {:noreply, %{state | nonces: nonces}}
  end

  # ---- Private helpers ------------------------------------------------------

  defp do_handle_challenge(params, state) do
    challenge_id    = Map.get(params, "challenge_id", "")
    nonce           = Map.get(params, "nonce", "")
    timestamp       = Map.get(params, "timestamp", 0)
    sender_pub_b64  = Map.get(params, "sender_public_key", "")
    sig_b64         = Map.get(params, "signature", "")

    now = System.os_time(:second)
    if abs(now - timestamp) > 300 do
      {:error, :timestamp_expired}
    else
      with {:ok, new_state}   <- check_nonce(nonce, state),
           {:ok, sender_pub}  <- safe_decode64(sender_pub_b64),
           {:ok, sig}         <- safe_decode64(sig_b64) do
        msg = "#{challenge_id}:#{nonce}"
        if :crypto.verify(:eddsa, :none, msg, sig, [sender_pub, :ed25519]) do
          priv    = :persistent_term.get(:l8_priv_key)
          our_sig = :crypto.sign(:eddsa, :none, msg, [priv, :ed25519]) |> Base.encode64()
          response = %{
            "challenge_id"        => challenge_id,
            "nonce"               => nonce,
            "receiver_signature"  => our_sig,
            "receiver_public_key" => pub_b64()
          }
          {:ok, response, new_state}
        else
          {:error, :invalid_signature}
        end
      else
        _ -> {:error, :bad_params}
      end
    end
  end

  defp check_nonce(nonce, state) do
    now = System.monotonic_time(:millisecond)
    if Map.has_key?(state.nonces, nonce) do
      {:error, :replay}
    else
      expiry = now + @nonce_ttl_ms
      {:ok, %{state | nonces: Map.put(state.nonces, nonce, expiry)}}
    end
  end

  defp run_handshake(domain) do
    well_known_url = "#{domain}/.well-known/l8"
    case fetch_json(well_known_url) do
      {:ok, meta} ->
        receiver_pub_b64    = Map.get(meta, "public_key", "")
        challenge_path      = Map.get(meta, "challenge_endpoint", "/l8/challenge")
        challenge_url       = if String.starts_with?(challenge_path, "http"),
          do: challenge_path,
          else: "#{domain}#{challenge_path}"

        challenge_id = random_uuid()
        nonce        = random_uuid()
        timestamp    = System.os_time(:second)
        priv         = :persistent_term.get(:l8_priv_key)
        msg          = "#{challenge_id}:#{nonce}"
        sig          = :crypto.sign(:eddsa, :none, msg, [priv, :ed25519]) |> Base.encode64()

        body = Jason.encode!(%{
          "challenge_id"      => challenge_id,
          "nonce"             => nonce,
          "timestamp"         => timestamp,
          "sender_public_key" => pub_b64(),
          "signature"         => sig
        })

        case post_json(challenge_url, body) do
          {:ok, resp} ->
            returned_sig_b64  = Map.get(resp, "receiver_signature", "")
            returned_pub_b64  = Map.get(resp, "receiver_public_key", receiver_pub_b64)
            with {:ok, receiver_pub} <- safe_decode64(returned_pub_b64),
                 {:ok, returned_sig} <- safe_decode64(returned_sig_b64),
                 true <- :crypto.verify(:eddsa, :none, msg, returned_sig, [receiver_pub, :ed25519]) do
              validated_at = System.os_time(:second)
              GenServer.call(__MODULE__, {:store_trust, domain, returned_pub_b64, validated_at})
              :ok
            else
              _ ->
                Logger.warning("[L8] Handshake signature verification failed for #{domain}")
                :skip
            end

          _ ->
            Logger.info("[L8] Challenge endpoint unavailable for #{domain}, skipping L8")
            :skip
        end

      _ ->
        Logger.info("[L8] No /.well-known/l8 at #{domain}, delivering without L8")
        :skip
    end
  end

  defp ets_trusted?(domain) do
    :ets.member(:l8_trust, domain)
  end

  defp domain_from_url(url) do
    uri          = URI.parse(url)
    scheme_port  = if uri.scheme == "https", do: 443, else: 80
    port_str     = if uri.port && uri.port != scheme_port, do: ":#{uri.port}", else: ""
    "#{uri.scheme}://#{uri.host}#{port_str}"
  end

  defp load_or_generate_key do
    case System.get_env("L8_PRIVATE_KEY") do
      nil ->
        key_path = System.get_env("L8_KEY_PATH") || @key_path
        load_or_generate_file_key(key_path)
      b64 ->
        <<priv::binary-size(32), pub::binary-size(32)>> = Base.decode64!(b64)
        {priv, pub}
    end
  end

  defp load_or_generate_file_key(path) do
    case File.read(path) do
      {:ok, <<priv::binary-size(32), pub::binary-size(32)>>} ->
        {priv, pub}
      _ ->
        {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
        File.write!(path, <<priv::binary, pub::binary>>)
        Logger.info("[L8] Generated new Ed25519 key, saved to #{path}")
        {priv, pub}
    end
  end

  defp load_trust_from_disk do
    trust_dir = System.get_env("L8_TRUST_DIR") || @trust_dir
    case File.ls(trust_dir) do
      {:ok, files} ->
        Enum.each(files, fn filename ->
          path = Path.join(trust_dir, filename)
          with {:ok, content}  <- File.read(path),
               {:ok, data}     <- Jason.decode(content),
               pub_b64 when is_binary(pub_b64) <- Map.get(data, "public_key"),
               {:ok, pub_bytes} <- safe_decode64(pub_b64) do
            domain       = Map.get(data, "domain", "")
            validated_at = Map.get(data, "validated_at", 0)
            :ets.insert(:l8_trust, {domain, pub_bytes, pub_b64, validated_at})
          end
        end)
      _ -> :ok
    end
  end

  defp write_trust_file(domain, pub_b64, validated_at) do
    trust_dir = System.get_env("L8_TRUST_DIR") || @trust_dir
    File.mkdir_p!(trust_dir)
    path    = Path.join(trust_dir, sanitize_domain(domain) <> ".json")
    content = Jason.encode!(%{
      "domain"           => domain,
      "public_key"       => pub_b64,
      "validated_at"     => validated_at,
      "protocol_version" => "0.1",
      "capabilities"     => ["signed_payloads"]
    })
    File.write!(path, content)
  end

  defp sanitize_domain(domain) do
    domain
    |> String.replace("://", "-")
    |> String.replace(":", "-")
    |> String.replace("/", "-")
  end

  defp fetch_json(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], []) do
      {:ok, {{_, 200, _}, _headers, body}} -> Jason.decode(to_string(body))
      _                                    -> :error
    end
  end

  defp post_json(url, body) do
    case :httpc.request(
      :post,
      {String.to_charlist(url), [], ~c"application/json", String.to_charlist(body)},
      [{:timeout, 5_000}],
      []
    ) do
      {:ok, {{_, status, _}, _headers, resp_body}} when status in 200..299 ->
        Jason.decode(to_string(resp_body))
      _ -> :error
    end
  end

  defp safe_decode64(b64) do
    try do
      {:ok, Base.decode64!(b64)}
    rescue
      _ -> :error
    end
  end

  defp random_uuid do
    hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    <<a::binary-8, b::binary-4, c::binary-4, d::binary-4, e::binary-12>> = hex
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end
end
