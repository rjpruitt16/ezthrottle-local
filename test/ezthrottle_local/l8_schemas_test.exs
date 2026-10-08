defmodule EzthrottleLocal.L8SchemasTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias EzthrottleLocal.L8.Schemas
  alias EzthrottleLocalWeb.JobController

  @v1 %{
    "type" => "object",
    "required" => ["model", "messages"],
    "properties" => %{"model" => %{"type" => "string"}, "messages" => %{"type" => "array"}}
  }
  @v2 %{
    "type" => "object",
    "required" => ["model", "input"],
    "properties" => %{"model" => %{"type" => "string"}, "input" => %{"type" => "string"}}
  }

  defmodule UpstreamPlug do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{request_path: "/.well-known/l8"} = conn, agent) do
      Agent.update(agent, &Map.update!(&1, :fetches, fn n -> n + 1 end))
      %{schema: schema, hash: hash} = Agent.get(agent, & &1)

      body =
        Jason.encode!(%{
          "protocol_version" => "0.2",
          "public_key" => "cGs=",
          "challenge_endpoint" => "/l8/challenge",
          "schema_hash" => hash,
          "request_schemas" => %{"POST /v1/chat" => schema}
        })

      conn |> put_resp_content_type("application/json") |> send_resp(200, body)
    end

    def call(conn, agent) do
      %{hash: hash} = Agent.get(agent, & &1)
      conn |> put_resp_header("x-aqueduct-schema-hash", hash) |> send_resp(200, "{}")
    end
  end

  setup do
    EzthrottleLocal.L8.forget_not_trusted()
    System.put_env("EZTHROTTLE_L8_SCHEMA_VALIDATION", "true")
    Application.put_env(:ezthrottle_local, :l8_schema_min_refetch_ms, 0)

    on_exit(fn ->
      System.delete_env("EZTHROTTLE_L8_SCHEMA_VALIDATION")
      Application.delete_env(:ezthrottle_local, :l8_schema_min_refetch_ms)
    end)

    start_supervised!(Schemas)
    {:ok, agent} = Agent.start_link(fn -> %{schema: @v1, hash: "sha256:v1", fetches: 0} end)
    port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {UpstreamPlug, agent}, port: port},
        id: :"schemas_#{port}"
      )
    )

    {:ok, base: "http://127.0.0.1:#{port}", agent: agent}
  end

  defp fetches(agent), do: Agent.get(agent, & &1.fetches)

  test "rejects mismatches, accepts valid bodies, skips unschema'd routes", %{
    base: base,
    agent: agent
  } do
    url = base <> "/v1/chat"

    assert {:error, %{route: "POST /v1/chat", schema_hash: "sha256:v1", detail: detail}} =
             Schemas.validate(url, "POST", ~s({"model":"m"}))

    assert detail =~ "messages"
    assert {:error, %{detail: "body is not valid JSON"}} = Schemas.validate(url, "post", "nope")
    assert :ok = Schemas.validate(url, "POST", ~s({"model":"m","messages":[]}))
    assert :ok = Schemas.validate(base <> "/v1/other", "POST", "anything")
    assert fetches(agent) == 1
  end

  test "one metadata fetch under concurrency", %{base: base, agent: agent} do
    1..50
    |> Enum.map(fn _ ->
      Task.async(fn -> Schemas.validate(base <> "/v1/chat", "POST", "{}") end)
    end)
    |> Enum.each(&Task.await/1)

    assert fetches(agent) == 1
  end

  test "a changed schema hash refetches; an unchanged one does not", %{base: base, agent: agent} do
    url = base <> "/v1/chat"
    v2_body = ~s({"model":"m","input":"hi"})
    assert {:error, _} = Schemas.validate(url, "POST", v2_body)

    Agent.update(agent, &%{&1 | schema: @v2, hash: "sha256:v2"})
    Schemas.observe_hash(url, "sha256:v1")
    assert {:error, _} = Schemas.validate(url, "POST", v2_body)

    Schemas.observe_hash(url, "sha256:v2")
    assert :ok = Schemas.validate(url, "POST", v2_body)
    assert fetches(agent) == 2
  end

  test "the dispatch path observes X-Aqueduct-Schema-Hash", %{base: base, agent: agent} do
    url = base <> "/v1/chat"
    assert :ok = Schemas.validate(url, "POST", ~s({"model":"m","messages":[]}))
    Agent.update(agent, &%{&1 | schema: @v2, hash: "sha256:v2"})

    job = %EzthrottleLocal.Job{
      id: "j",
      user_id: "u",
      idempotent_key: "k",
      url: url,
      method: "POST",
      headers: %{},
      body: "{}",
      webhook_url: "https://example.com/cb"
    }

    {:ok, _} = EzthrottleLocal.AccountQueue.make_request(job, url, 1.0, 1, :shared, 5_000)
    assert :ok = Schemas.validate(url, "POST", ~s({"model":"m","input":"hi"}))
  end

  test "external $ref is never fetched", %{agent: agent} do
    test_pid = self()

    defmodule RefPlug do
      import Plug.Conn
      def init(pid), do: pid

      def call(conn, pid) do
        send(pid, :ref_fetched)
        send_resp(conn, 200, ~s({"type":"object"}))
      end
    end

    ref_port = Enum.random(20_000..60_000)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {RefPlug, test_pid}, port: ref_port},
        id: :"ref_#{ref_port}"
      )
    )

    port = Enum.random(20_000..60_000)

    {:ok, ref_agent} =
      Agent.start_link(fn ->
        %{
          schema: %{"$ref" => "http://127.0.0.1:#{ref_port}/s.json"},
          hash: "sha256:ref",
          fetches: 0
        }
      end)

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: {UpstreamPlug, ref_agent}, port: port},
        id: :"refup_#{port}"
      )
    )

    assert :ok = Schemas.validate("http://127.0.0.1:#{port}/v1/chat", "POST", "{}")
    refute_receive :ref_fetched, 200
    assert fetches(agent) == 0
  end

  test "POST /jobs and POST /proxy return 422 on mismatch", %{base: base} do
    for {action, path} <- [{:create, "/jobs"}, {:proxy, "/proxy"}] do
      params = %{
        "user_id" => "agent-a",
        "idempotent_key" => "schema-#{path}-#{System.unique_integer([:positive])}",
        "url" => base <> "/v1/chat",
        "method" => "POST",
        "body" => ~s({"model":"m"}),
        "webhook_url" => "https://example.com/callback"
      }

      conn = apply(JobController, action, [build_conn(:post, path, params), params])
      assert conn.status == 422, "#{path}: #{conn.resp_body}"
      body = Jason.decode!(conn.resp_body)
      assert body["schema_route"] == "POST /v1/chat"
      assert body["schema_hash"] == "sha256:v1"
      assert body["schema_errors"] =~ "messages"
    end
  end

  test "validation is a no-op when the flag is off", %{base: base, agent: agent} do
    System.delete_env("EZTHROTTLE_L8_SCHEMA_VALIDATION")
    assert :ok = Schemas.validate(base <> "/v1/chat", "POST", "nope")
    assert fetches(agent) == 0
  end
end
