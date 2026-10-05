defmodule EzthrottleLocal.L8EncryptionTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.L8

  defmodule ReceiverPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{request_path: "/.well-known/l8"} = conn, opts) do
      meta = %{
        "protocol_version" => "0.2",
        "public_key" => Base.encode64(opts.sign_pub),
        "challenge_endpoint" => "/l8/challenge",
        "capabilities" =>
          ["signed_payloads"] ++ if(opts.encrypt, do: ["encrypted_payloads"], else: [])
      }

      meta =
        if opts.encrypt,
          do: Map.put(meta, "encryption_public_key", Base.encode64(opts.enc_pub)),
          else: meta

      conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(meta))
    end

    def call(%{request_path: "/l8/challenge"} = conn, opts) do
      {:ok, raw, conn} = read_body(conn)
      req = Jason.decode!(raw)
      msg = "#{req["challenge_id"]}:#{req["nonce"]}"
      sig = :crypto.sign(:eddsa, :none, msg, [opts.sign_priv, :ed25519])

      body =
        Jason.encode!(%{
          "challenge_id" => req["challenge_id"],
          "nonce" => req["nonce"],
          "receiver_signature" => Base.encode64(sig),
          "receiver_public_key" => Base.encode64(opts.sign_pub)
        })

      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      send(opts.test_pid, {:delivery, conn.req_headers, body})
      send_resp(conn, 200, "ok")
    end
  end

  setup do
    trust_dir =
      Path.join(System.tmp_dir!(), "l8-trust-test-#{System.unique_integer([:positive])}")

    System.put_env("L8_TRUST_DIR", trust_dir)

    on_exit(fn ->
      System.delete_env("L8_TRUST_DIR")
      File.rm_rf(trust_dir)
    end)

    :ok
  end

  defp start_receiver(encrypt) do
    {sign_pub, sign_priv} = :crypto.generate_key(:eddsa, :ed25519)
    {enc_pub, enc_priv} = :crypto.generate_key(:ecdh, :x25519)
    port = Enum.random(20_000..60_000)

    opts = %{
      sign_pub: sign_pub,
      sign_priv: sign_priv,
      enc_pub: enc_pub,
      enc_priv: enc_priv,
      encrypt: encrypt,
      test_pid: self()
    }

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {ReceiverPlug, opts}, port: port},
        id: :"l8_rcv_#{port}"
      )
    )

    Map.put(opts, :url, "http://127.0.0.1:#{port}")
  end

  defp header(headers, name), do: headers |> List.keyfind(name, 0) |> elem(1)

  defp assert_signed_over(headers, body) do
    hash = :crypto.hash(:sha256, body) |> Base.encode64()
    msg = "#{header(headers, "x-l8-delivery-id")}.#{header(headers, "x-l8-timestamp")}.#{hash}"
    sig = Base.decode64!(header(headers, "x-l8-signature"))
    sender_pub = :persistent_term.get(:l8_pub_key)
    assert :crypto.verify(:eddsa, :none, msg, sig, [sender_pub, :ed25519])
  end

  test "seal/open round trip and tamper detection" do
    {pub, priv} = :crypto.generate_key(:ecdh, :x25519)
    plaintext = ~s({"body":"secret"})
    {sealed, h} = L8.seal_payload(pub, plaintext, "d1", "100")
    refute sealed =~ "secret"

    open = fn sealed, id, ts ->
      L8.open_payload(priv, pub, sealed, h["X-L8-Ephemeral-Key"], h["X-L8-Nonce"], id, ts)
    end

    assert {:ok, ^plaintext} = open.(sealed, "d1", "100")
    <<first, rest::binary>> = sealed
    assert :error = open.(<<Bitwise.bxor(first, 1), rest::binary>>, "d1", "100")
    assert :error = open.(sealed, "d2", "100")
    assert :error = open.(sealed, "d1", "101")
  end

  test "webhook to an encrypting receiver is encrypted, then signed over the ciphertext" do
    rcv = start_receiver(true)

    assert :ok =
             EzthrottleLocal.Webhook.deliver(rcv.url <> "/hook", %{
               "job_id" => "j1",
               "body" => "secret"
             })

    assert_receive {:delivery, headers, body}, 5_000
    assert header(headers, "x-l8-encryption") == "x25519-hkdf-sha256-aes256gcm"
    assert header(headers, "content-type") =~ "application/l8-encrypted"
    assert header(headers, "x-l8-content-type") == "application/json"
    refute body =~ "secret"
    assert_signed_over(headers, body)

    {:ok, plain} =
      L8.open_payload(
        rcv.enc_priv,
        rcv.enc_pub,
        body,
        header(headers, "x-l8-ephemeral-key"),
        header(headers, "x-l8-nonce"),
        header(headers, "x-l8-delivery-id"),
        header(headers, "x-l8-timestamp")
      )

    assert Jason.decode!(plain)["body"] == "secret"
  end

  test "receiver without encrypted_payloads gets signed plaintext" do
    rcv = start_receiver(false)
    assert :ok = EzthrottleLocal.Webhook.deliver(rcv.url <> "/hook", %{"body" => "visible"})

    assert_receive {:delivery, headers, body}, 5_000
    assert List.keyfind(headers, "x-l8-encryption", 0) == nil
    assert body =~ "visible"
    assert_signed_over(headers, body)
  end

  test "queued webhook delivery jobs are encrypted too" do
    rcv = start_receiver(true)

    job = %EzthrottleLocal.Job{
      id: "w1",
      user_id: "u",
      idempotent_key: "webhook:j1",
      url: rcv.url <> "/hook",
      method: "POST",
      headers: %{"Content-Type" => "application/json"},
      body: ~s({"body":"secret"}),
      webhook_url: ""
    }

    {:ok, %{status: 200}} =
      EzthrottleLocal.AccountQueue.make_request(job, job.url, 1.0, 1, :shared, 5_000)

    assert_receive {:delivery, headers, body}, 5_000
    refute body =~ "secret"
    assert [_] = Enum.filter(headers, fn {k, _} -> k == "content-type" end)
    assert_signed_over(headers, body)
  end

  test "invalidate drops trust so the handshake re-runs" do
    rcv = start_receiver(true)
    :ok = L8.ensure_trust(rcv.url)
    assert L8.is_trusted?(rcv.url)
    L8.invalidate(rcv.url)
    refute L8.is_trusted?(rcv.url)
  end
end
