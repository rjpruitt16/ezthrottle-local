defmodule EzthrottleLocalWeb.L8Controller do
  use EzthrottleLocalWeb, :controller

  def well_known(conn, _params) do
    json(conn, EzthrottleLocal.L8.meta(conn.host))
  end

  def challenge(conn, params) do
    case EzthrottleLocal.L8.handle_challenge(params) do
      {:ok, response}             -> json(conn, response)
      {:error, :timestamp_expired} -> conn |> put_status(400) |> json(%{error: "timestamp expired"})
      {:error, :replay}            -> conn |> put_status(400) |> json(%{error: "nonce already seen"})
      {:error, _}                  -> conn |> put_status(400) |> json(%{error: "invalid challenge"})
    end
  end

  def spec(conn, _params) do
    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, l8_spec_document())
  end

  defp l8_spec_document do
    """
    # L8 Protocol — v0.1

    **Trustless webhook delivery via Ed25519 public key handshake.**

    No shared secrets. No central authority. Ownership proven once via a signed challenge.
    All future deliveries carry headers the receiver verifies locally — no database lookup, no round-trip.

    ---

    ## Why L8

    Traditional webhook security stores a shared HMAC secret on both sides. That secret can be stolen,
    logged by accident, or forgotten to rotate. A compromised secret lets anyone forge deliveries silently.

    L8 replaces the shared secret with public key cryptography. There is no secret to steal from a database.
    Verification is a single local `Ed25519.verify()` call against a cached public key — microseconds, zero network calls.

    ---

    ## How it works

    1. Receiver publishes a public key at `GET /.well-known/l8`
    2. Sender fetches that key and issues a signed challenge to prove both parties own their private keys
    3. Trust is cached to disk as `l8-trust/{domain}.json` — the handshake runs once per domain
    4. Every webhook delivery carries `X-L8-Signature` headers the receiver verifies locally

    ---

    ## Receiver endpoints (implement these to support L8)

    ### GET /.well-known/l8

    ```json
    {
      "protocol_version":     "0.1",
      "service_name":         "your-service",
      "public_key":           "<base64 Ed25519 public key>",
      "challenge_endpoint":   "/l8/challenge",
      "supported_algorithms": ["ed25519"],
      "capabilities":         ["signed_payloads"]
    }
    ```

    ### POST /l8/challenge

    Sender request:
    ```json
    {
      "challenge_id":      "<uuid>",
      "nonce":             "<uuid>",
      "timestamp":         1740000000,
      "sender_public_key": "<base64 Ed25519 public key>",
      "signature":         "<base64 Ed25519 sig of 'challenge_id:nonce'>"
    }
    ```

    Your response:
    ```json
    {
      "challenge_id":        "<same uuid>",
      "nonce":               "<same nonce>",
      "receiver_signature":  "<base64 Ed25519 sig of 'challenge_id:nonce'>",
      "receiver_public_key": "<base64 Ed25519 public key>"
    }
    ```

    **Reject if:** timestamp is older than 5 minutes, or nonce has been seen before (replay protection).

    ---

    ## Signed delivery headers

    After trust is established, all webhook POST requests include:

    ```
    X-L8-Delivery-Id: <uuid>
    X-L8-Timestamp:   <unix seconds>
    X-L8-Key-Id:      <base64 first 8 bytes of sender public key>
    X-L8-Signature:   <base64 Ed25519 sig of '{delivery_id}.{timestamp}.{base64(sha256(body))}'>
    ```

    ---

    ## Verification

    ```python
    import base64, hashlib
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    def verify_l8(headers, body: bytes, sender_public_key_b64: str):
        pub = Ed25519PublicKey.from_public_bytes(base64.b64decode(sender_public_key_b64))
        delivery_id = headers["X-L8-Delivery-Id"]
        timestamp   = headers["X-L8-Timestamp"]
        body_hash   = base64.b64encode(hashlib.sha256(body).digest()).decode()
        msg = f"{delivery_id}.{timestamp}.{body_hash}".encode()
        sig = base64.b64decode(headers["X-L8-Signature"])
        pub.verify(sig, msg)  # raises InvalidSignature if tampered
    ```

    **On verification failure:** re-fetch the sender's `/.well-known/l8` to get a fresh public key
    (handles key rotation), then retry once before rejecting.

    ---

    ## Trust cache

    One file per trusted domain: `l8-trust/{domain}.json`

    ```json
    {
      "domain":           "https://example.com",
      "public_key":       "<base64>",
      "validated_at":     1740000000,
      "protocol_version": "0.1",
      "capabilities":     ["signed_payloads"]
    }
    ```

    To revoke: delete the file. The handshake re-runs on next delivery.

    ---

    ## Key management

    | Method | How |
    |--------|-----|
    | Environment variable | `L8_PRIVATE_KEY=<base64 raw Ed25519 private key (64 bytes: seed || pubkey)>` |
    | Key file | `.l8-key` — 64 raw bytes, auto-generated on first start |

    Only the private key is needed. The public key is derived from it.

    ---

    ## Graceful degradation

    L8 is opt-in. If `/.well-known/l8` returns non-200, delivery proceeds without signed headers.
    Receivers that don't implement L8 are completely unaffected.

    ---

    ## Spec

    Machine-readable spec: https://rjpruitt16.github.io/l8-protocol/spec.json
    """
  end
end
