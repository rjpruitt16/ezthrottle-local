defmodule EzthrottleLocal.ExecutionDeadlineTest do
  use ExUnit.Case, async: false

  alias EzthrottleLocal.AccountQueue
  alias EzthrottleLocal.IdempotentStore
  alias EzthrottleLocal.Job

  test "job accepts and preserves execute_before" do
    execute_before = System.system_time(:millisecond) + 60_000

    assert {:ok, job} =
             Job.new(%{
               "user_id" => "deadline-user",
               "idempotent_key" => unique("parse"),
               "url" => "http://127.0.0.1:1",
               "method" => "POST",
               "webhook_url" => "http://127.0.0.1:1/hook",
               "execute_before" => execute_before
             })

    assert job.execute_before == execute_before
  end

  test "expired queued job fails without dispatch" do
    job = %Job{
      id: unique("job"),
      user_id: "deadline-user",
      idempotent_key: unique("key"),
      url: "http://127.0.0.1:1/should-not-run",
      method: "POST",
      headers: %{},
      body: "",
      webhook_url: "",
      status: :queued,
      created_at: System.system_time(:millisecond),
      execute_before: System.system_time(:millisecond) - 1_000
    }

    {:ok, queue} =
      AccountQueue.start_link(
        queue_key: unique("queue"),
        upstream: "http://127.0.0.1:1",
        max_concurrent: 1,
        rps: 100.0
      )

    assert {:accepted, ^job} = AccountQueue.submit(queue, job)
    assert wait_until(fn -> IdempotentStore.get_status(job.id) == "failed" end)
    assert IdempotentStore.get_result(job.id)["reason"] == "execution_deadline_exceeded"

    if Process.alive?(queue), do: GenServer.stop(queue)
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 1_000) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(5) && wait_until(fun, deadline)
    end
  end
end
