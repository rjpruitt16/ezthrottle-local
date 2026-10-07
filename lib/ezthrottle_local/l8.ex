defmodule EzthrottleLocal.L8 do
  @moduledoc false
  use GenServer
  require Logger

  @key_path ".l8-key"
  @trust_dir "l8-trust"
  @nonce_ttl_ms 300_000
  @spec_url "https://rjpruitt16.github.io/l8-protocol/spec.json"
  @version "0.2"
  @enc_algorithm "x25519-hkdf-sha256-aes256gcm"
  @enc_capability "encrypted_payloads"
  @enc_content_type "application/l8-encrypted"
  @enc_info "l8/0.2 payload"

  # ---- Public API -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def pub_b64, do: :persistent_term.get(:l8_pub_b64)

  def version, do: @version

  def meta(_host) do
    %{
      "protocol_version"     => @version,
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

    cond do
      ets_trusted?(domain) -> :ok
      recently_not_l8?(domain) -> :skip
      true -> run_handshake(domain)
    end
  end

  # Receivers without /.well-known/l8 are remembered for this long before
  # being probed again (they may add L8 later). Without it every webhook to
  # such a receiver cost an extra HTTP request, a fresh :httpc connection
  # and a log line. Mirrors Aquifer's l8NegativeTTL.
  @not_l8_ttl_ms 5 * 60 * 1000

  defp recently_not_l8?(domain) do
    case :ets.lookup(:l8_not_trusted, domain) do
      [{^domain, at}] -> System.monotonic_time(:millisecond) - at < @not_l8_ttl_ms
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  defp remember_not_l8(domain) do
    :ets.insert(:l8_not_trusted, {domain, System.monotonic_time(:millisecond)})
  rescue
    ArgumentError -> :ok
  end

  def is_trusted?(url), do: ets_trusted?(domain_from_url(url))

  @doc """
  Prepares an outgoing webhook body for an L8-trusted receiver: encrypt to
  the receiver's X25519 key when it advertised one, then sign the bytes
  actually sent (encrypt-then-sign). Untrusted receivers get the body back
  unchanged with no headers. Mirrors Aquifer's L8Registry.SealDelivery.
  """
  def seal_delivery(url, body, content_type) when is_binary(body) do
    case :ets.lookup(:l8_trust, domain_from_url(url)) do
      [] ->
        {:ok, body, %{}}

      [{_domain, _pub, _pub_b64, _validated_at, enc_pub}] ->
        delivery_id = random_uuid()
        timestamp = Integer.to_string(System.os_time(:second))

        {body, enc_headers} =
          if is_binary(enc_pub) do
            {ciphertext, headers} = seal_payload(enc_pub, body, delivery_id, timestamp)

            {ciphertext,
             Map.merge(headers, %{
               "X-L8-Content-Type" => content_type,
               "Content-Type" => @enc_content_type
             })}
          else
            {body, %{}}
          end

        {:ok, body, Map.merge(enc_headers, sign_headers(body, delivery_id, timestamp))}
    end
  end

  @doc """
  Drops the trust (and its file) for a domain so the next delivery re-runs
  the handshake. Used when an upstream's X-Aqueduct-Schema-Hash changes.
  """
  def invalidate(url) do
    domain = domain_from_url(url)
    :ets.delete(:l8_trust, domain)
    trust_dir = System.get_env("L8_TRUST_DIR") || @trust_dir
    File.rm(Path.join(trust_dir, sanitize_domain(domain) <> ".json"))
    :ok
  end

  @doc false
  def seal_payload(receiver_pub, plaintext, delivery_id, timestamp) do
    {eph_pub, eph_priv} = :crypto.generate_key(:ecdh, :x25519)
    key = payload_key(eph_priv, receiver_pub, eph_pub, receiver_pub)
    nonce = :crypto.strong_rand_bytes(12)
    aad = "#{delivery_id}.#{timestamp}"
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad, true)

    {ciphertext <> tag,
     %{
       "X-L8-Encryption" => @enc_algorithm,
       "X-L8-Ephemeral-Key" => Base.encode64(eph_pub),
       "X-L8-Nonce" => Base.encode64(nonce)
     }}
  end

  @doc false
  def open_payload(receiver_priv, receiver_pub, sealed, eph_b64, nonce_b64, delivery_id, timestamp)
      when byte_size(sealed) >= 16 do
    with {:ok, eph_pub} <- Base.decode64(eph_b64),
         {:ok, nonce} <- Base.decode64(nonce_b64) do
      key = payload_key(receiver_priv, eph_pub, eph_pub, receiver_pub)
      ct_size = byte_size(sealed) - 16
      <<ciphertext::binary-size(ct_size), tag::binary-16>> = sealed
      aad = "#{delivery_id}.#{timestamp}"

      case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, aad, tag, false) do
        :error -> :error
        plaintext -> {:ok, plaintext}
      end
    else
      _ -> :error
    end
  end

  def open_payload(_priv, _pub, _sealed, _eph, _nonce, _id, _ts), do: :error

  # HKDF-SHA256 (RFC 5869) with a single 32-byte output block.
  defp payload_key(priv, peer_pub, eph_pub, receiver_pub) do
    shared = :crypto.compute_key(:ecdh, peer_pub, priv, :x25519)
    prk = :crypto.mac(:hmac, :sha256, eph_pub <> receiver_pub, shared)
    :crypto.mac(:hmac, :sha256, prk, @enc_info <> <<1>>)
  end

  defp sign_headers(body, delivery_id, timestamp) do
    priv = :persistent_term.get(:l8_priv_key)
    pub = :persistent_term.get(:l8_pub_key)
    body_hash = :crypto.hash(:sha256, body) |> Base.encode64()
    message = "#{delivery_id}.#{timestamp}.#{body_hash}"
    sig = :crypto.sign(:eddsa, :none, message, [priv, :ed25519]) |> Base.encode64()

    %{
      "X-L8-Delivery-Id" => delivery_id,
      "X-L8-Timestamp" => timestamp,
      "X-L8-Key-Id" => binary_part(pub, 0, 8) |> Base.encode64(),
      "X-L8-Signature" => sig
    }
  end

  # Only a receiver that both advertises the capability and supplies a valid
  # 32-byte key gets encrypted deliveries; anything else stays signed plaintext.
  defp encryption_key(capabilities, key_b64)
       when is_list(capabilities) and is_binary(key_b64) do
    with true <- @enc_capability in capabilities,
         {:ok, <<_::binary-32>> = key} <- Base.decode64(key_b64) do
      key
    else
      _ -> nil
    end
  end

  defp encryption_key(_capabilities, _key_b64), do: nil

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts) do
    {priv, pub} = load_or_generate_key()
    pub_b64 = Base.encode64(pub)
    :persistent_term.put(:l8_priv_key, priv)
    :persistent_term.put(:l8_pub_key, pub)
    :persistent_term.put(:l8_pub_b64, pub_b64)
    :ets.new(:l8_trust, [:named_table, :public, read_concurrency: true])
    :ets.new(:l8_not_trusted, [:named_table, :public, read_concurrency: true])
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
  def handle_call({:store_trust, domain, pub_b64, validated_at, meta}, _from, state) do
    pub_bytes = Base.decode64!(pub_b64)
    capabilities = Map.get(meta, "capabilities", [])
    enc_b64 = Map.get(meta, "encryption_public_key")
    enc_pub = encryption_key(capabilities, enc_b64)
    :ets.insert(:l8_trust, {domain, pub_bytes, pub_b64, validated_at, enc_pub})
    write_trust_file(domain, pub_b64, validated_at, capabilities, enc_pub && enc_b64)
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
    case fetch_meta(domain) do
      {:ok, meta} ->
        :ets.delete(:l8_not_trusted, domain)
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
              GenServer.call(__MODULE__, {:store_trust, domain, returned_pub_b64, validated_at, meta})
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
        remember_not_l8(domain)
        :skip
    end
  end

  defp ets_trusted?(domain) do
    :ets.member(:l8_trust, domain)
  end

  def domain_from_url(url) do
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
            enc_pub = encryption_key(Map.get(data, "capabilities"), Map.get(data, "encryption_public_key"))
            :ets.insert(:l8_trust, {domain, pub_bytes, pub_b64, validated_at, enc_pub})
          end
        end)
      _ -> :ok
    end
  end

  defp write_trust_file(domain, pub_b64, validated_at, capabilities, enc_b64) do
    trust_dir = System.get_env("L8_TRUST_DIR") || @trust_dir
    File.mkdir_p!(trust_dir)
    path    = Path.join(trust_dir, sanitize_domain(domain) <> ".json")

    content =
      %{
        "domain"           => domain,
        "public_key"       => pub_b64,
        "validated_at"     => validated_at,
        "protocol_version" => @version,
        "capabilities"     => capabilities
      }
      |> then(fn data -> if enc_b64, do: Map.put(data, "encryption_public_key", enc_b64), else: data end)
      |> Jason.encode!()

    File.write!(path, content)
  end

  defp sanitize_domain(domain) do
    domain
    |> String.replace("://", "-")
    |> String.replace(":", "-")
    |> String.replace("/", "-")
  end

  @doc "Fetches a domain's /.well-known/l8 metadata."
  def fetch_meta(domain), do: fetch_json("#{domain}/.well-known/l8")

  @meta_max_bytes 1_048_576

  defp fetch_json(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, 5_000}], [body_format: :binary]) do
      {:ok, {{_, 200, _}, _headers, body}} when byte_size(body) <= @meta_max_bytes -> Jason.decode(body)
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
