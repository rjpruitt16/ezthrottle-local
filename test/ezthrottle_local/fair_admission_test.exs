defmodule EzthrottleLocal.FairAdmissionTest do
  use ExUnit.Case, async: true

  alias EzthrottleLocal.FairAdmission

  test "single active queue borrows the whole budget" do
    assert {:allowed, snapshot} = FairAdmission.decide(99, 99, 1, 100, 0.0)
    assert snapshot.queue_backlog == 100
    assert snapshot.upstream_backlog == 100
  end

  test "global budget rejects only after it is full" do
    assert {:rejected, "upstream_queue", snapshot} =
             FairAdmission.decide(100, 100, 1, 100, 0.99)

    assert snapshot.rejection_probability == 1.0
  end

  test "pressure rejects the noisy queue without rejecting the quiet queue" do
    assert {:rejected, "queue_fair_share", noisy} =
             FairAdmission.decide(89, 94, 2, 100, 0.0)

    assert noisy.rejection_probability > 0
    assert {:allowed, _quiet} = FairAdmission.decide(5, 94, 2, 100, 0.0)
  end

  test "unused capacity remains borrowable below the pressure threshold" do
    assert {:allowed, snapshot} = FairAdmission.decide(60, 60, 2, 100, 0.0)
    assert snapshot.admission_pressure == 0.0
  end

  test "rejection becomes less aggressive as competitors leave" do
    {:allowed, four_queues} = FairAdmission.decide(79, 89, 4, 100, 0.99)
    {:allowed, two_queues} = FairAdmission.decide(79, 89, 2, 100, 0.99)

    assert four_queues.rejection_probability > two_queues.rejection_probability
  end
end
