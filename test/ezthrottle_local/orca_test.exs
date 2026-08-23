defmodule EzthrottleLocal.OrcaTest do
  use ExUnit.Case, async: true

  alias EzthrottleLocal.Orca

  test "parses real vLLM TEXT format" do
    headers = %{"endpoint-load-metrics" => "TEXT named_metrics.kv_cache_usage_perc=0.85"}
    assert Orca.rps(headers) == 2.0
  end

  test "parses JSON format" do
    headers = %{
      "endpoint-load-metrics" =>
        ~s(JSON {"named_metrics":{"kv_cache_usage_perc":0.75}})
    }

    assert Orca.rps(headers) == 2.0
  end

  test "no override when healthy" do
    headers = %{"endpoint-load-metrics" => "TEXT named_metrics.kv_cache_usage_perc=0.40"}
    assert Orca.rps(headers) == nil
  end

  test "missing header returns nil" do
    assert Orca.rps(%{}) == nil
  end

  test "missing kv_cache metric returns nil" do
    headers = %{"endpoint-load-metrics" => "TEXT named_metrics.num_requests_waiting=3"}
    assert Orca.rps(headers) == nil
  end

  test "malformed header does not raise" do
    headers = %{"endpoint-load-metrics" => "not a valid orca payload at all"}
    assert Orca.rps(headers) == nil

    headers2 = %{"endpoint-load-metrics" => "JSON {not even valid json"}
    assert Orca.rps(headers2) == nil
  end

  test "load-to-rps curve matches Aquifer's thresholds" do
    text = fn util -> "TEXT named_metrics.kv_cache_usage_perc=#{util}" end

    assert Orca.rps(%{"endpoint-load-metrics" => text.(0.69)}) == nil
    assert Orca.rps(%{"endpoint-load-metrics" => text.(0.70)}) == 2.0
    assert Orca.rps(%{"endpoint-load-metrics" => text.(0.89)}) == 2.0
    assert Orca.rps(%{"endpoint-load-metrics" => text.(0.90)}) == 0.5
    assert Orca.rps(%{"endpoint-load-metrics" => text.(0.96)}) == 0.5
    assert Orca.rps(%{"endpoint-load-metrics" => text.(0.97)}) == 0.25
    assert Orca.rps(%{"endpoint-load-metrics" => text.(1.00)}) == 0.25
  end

  test "request_header_name matches vLLM's actual opt-in header" do
    assert Orca.request_header_name() == "endpoint-load-metrics-format"
  end
end
