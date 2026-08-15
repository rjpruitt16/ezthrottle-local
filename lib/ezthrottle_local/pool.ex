defmodule EzthrottleLocal.Pool do
  @moduledoc """
  GenServer owning one named pool's membership, selection, and
  reputation state — the Elixir port of Aquifer's Pool (pool.go), built
  after the Go implementation was proven out first.

  Selection is virtual-time weighted round robin: each pick advances the
  chosen member's virtual position by 1/weight (a higher-weight member
  advances less per pick, so it returns to the front sooner and gets
  picked proportionally more often). This is implemented with `:gb_trees`
  keyed on `{virtual_position, member_id}` as the OTP-native equivalent of
  Go's `container/heap` — both give O(log n) insert/smallest/delete,
  which is what makes a pick O(log n) instead of the O(n) per pick the
  naive nginx-style smooth-weighted-round-robin algorithm needs (it
  recomputes every member's running counter on every pick; this only
  ever touches the one member actually selected).

  A single GenServer process per pool means no explicit locking is
  needed for any of this — mutations are already serialized by the
  mailbox, the same way Aquifer's single-goroutine-owned AccountQueue
  needed no lock for its own queue.
  """

  use GenServer
  require Logger

  alias EzthrottleLocal.PoolMember

  # Under halving-per-failure, 4 consecutive failures brings reputation to
  # 2^-4 = 0.0625, just above this floor -- so a member has to be
  # consistently bad, not unlucky once, before it's even a candidate for
  # eviction.
  @reputation_floor 0.05

  # How long reputation must stay at or below the floor, continuously,
  # before a member is actually removed. This -- not the failure count
  # alone -- is what answers "how many 500s before we conclude it's
  # gone": any success resets this clock even if reputation itself hasn't
  # numerically recovered above the floor yet, so a member has to be
  # consistently bad with zero interrupting successes, not just unlucky.
  # Reads from config (default 12s) rather than a fixed attribute so
  # tests can shrink it instead of sleeping the real window.
  defp floor_eviction_window_ms do
    Application.get_env(:ezthrottle_local, :pool_floor_eviction_window_ms, 12_000)
  end

  # Nudges reputation back toward 1.0 on success rather than resetting it
  # instantly -- a single success after a long bad streak shouldn't
  # immediately restore full trust.
  @reputation_recovery_factor 1.5

  # Missing this many consecutive expected heartbeats (relative to the
  # member's own declared interval) evicts it for having gone silent,
  # independent of the reputation/failure path -- catches a member that
  # crashed or partitioned without ever being dispatched to.
  @heartbeat_miss_limit 3
  @heartbeat_sweep_ms 5_000

  @type t :: %__MODULE__{
          pool_id: String.t(),
          members: %{optional(String.t()) => PoolMember.t()},
          order: :gb_trees.tree({float(), String.t()}, String.t())
        }

  defstruct [:pool_id, members: %{}, order: :gb_trees.empty()]

  # ---- Public API ----

  def start_link(pool_id) when is_binary(pool_id) do
    GenServer.start_link(__MODULE__, pool_id)
  end

  @doc """
  Adds a new member or refreshes an existing one. The same call serves as
  both initial registration and heartbeat -- re-calling it resets the
  liveness timer and updates declared capacity.
  """
  @spec register(pid(), String.t(), String.t(), float(), non_neg_integer()) :: :ok
  def register(pid, member_id, address, declared_rps, heartbeat_interval_ms) do
    GenServer.call(pid, {:register, member_id, address, declared_rps, heartbeat_interval_ms})
  end

  @doc "Selects a member proportional to declared_rps x reputation. Returns nil if the pool has no members."
  @spec pick(pid()) :: PoolMember.t() | nil
  def pick(pid), do: GenServer.call(pid, :pick)

  @doc "Nudges a member's reputation back toward full trust and clears any in-progress floor-eviction timer."
  @spec record_success(pid(), String.t()) :: :ok
  def record_success(pid, member_id), do: GenServer.cast(pid, {:record_success, member_id})

  @doc "Halves a member's reputation. Returns true if this call caused an eviction."
  @spec record_failure(pid(), String.t()) :: boolean()
  def record_failure(pid, member_id), do: GenServer.call(pid, {:record_failure, member_id})

  @doc "Live sum of every member's current effective weight -- the pool's aggregate ceiling."
  @spec total_capacity(pid()) :: float()
  def total_capacity(pid), do: GenServer.call(pid, :total_capacity)

  @spec size(pid()) :: non_neg_integer()
  def size(pid), do: GenServer.call(pid, :size)

  @spec snapshot(pid()) :: [map()]
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  # ---- GenServer callbacks ----

  @impl true
  def init(pool_id) do
    schedule_heartbeat_sweep()
    {:ok, %__MODULE__{pool_id: pool_id}}
  end

  @impl true
  def handle_call({:register, id, address, declared_rps, heartbeat_interval_ms}, _from, state) do
    now = System.monotonic_time(:millisecond)

    case Map.get(state.members, id) do
      nil ->
        # A brand new member is seeded at the current minimum virtual
        # position (not 0) so it competes fairly immediately -- starting
        # at 0 when existing members have advanced well past that would
        # let a newcomer dominate selection until it "catches up."
        start_pos =
          if :gb_trees.is_empty(state.order) do
            0.0
          else
            # :gb_trees.smallest/1 returns {Key, Value}, and Key here is
            # itself the {position, id} tuple used as the tree key -- so
            # the position is one level deeper than it looks.
            {{pos, _id}, _val} = :gb_trees.smallest(state.order)
            pos
          end

        member = %PoolMember{
          id: id,
          address: address,
          declared_rps: declared_rps,
          heartbeat_interval_ms: heartbeat_interval_ms,
          last_heartbeat: now,
          reputation: 1.0,
          virtual_position: start_pos,
          floor_since: nil
        }

        order = :gb_trees.insert({start_pos, id}, id, state.order)
        members = Map.put(state.members, id, member)
        {:reply, :ok, %{state | members: members, order: order}}

      existing ->
        updated = %{
          existing
          | address: address,
            declared_rps: declared_rps,
            heartbeat_interval_ms: heartbeat_interval_ms,
            last_heartbeat: now
        }

        {:reply, :ok, %{state | members: Map.put(state.members, id, updated)}}
    end
  end

  @impl true
  def handle_call(:pick, _from, state) do
    if :gb_trees.is_empty(state.order) do
      {:reply, nil, state}
    else
      {{pos, id}, _val, order1} = :gb_trees.take_smallest(state.order)
      member = Map.fetch!(state.members, id)
      new_pos = pos + 1.0 / PoolMember.weight(member)
      updated = %{member | virtual_position: new_pos}
      order2 = :gb_trees.insert({new_pos, id}, id, order1)
      members = Map.put(state.members, id, updated)
      {:reply, updated, %{state | members: members, order: order2}}
    end
  end

  @impl true
  def handle_call({:record_failure, id}, _from, state) do
    case Map.get(state.members, id) do
      nil ->
        {:reply, false, state}

      member ->
        now = System.monotonic_time(:millisecond)
        new_reputation = member.reputation * 0.5

        if new_reputation <= @reputation_floor do
          floor_since = member.floor_since || now

          if now - floor_since >= floor_eviction_window_ms() do
            {:reply, true, evict(state, member)}
          else
            updated = %{member | reputation: new_reputation, floor_since: floor_since}
            {:reply, false, %{state | members: Map.put(state.members, id, updated)}}
          end
        else
          updated = %{member | reputation: new_reputation, floor_since: nil}
          {:reply, false, %{state | members: Map.put(state.members, id, updated)}}
        end
    end
  end

  @impl true
  def handle_call(:total_capacity, _from, state) do
    total =
      state.members
      |> Map.values()
      |> Enum.reduce(0.0, fn m, acc -> acc + PoolMember.weight(m) end)

    {:reply, total, state}
  end

  @impl true
  def handle_call(:size, _from, state), do: {:reply, map_size(state.members), state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap =
      state.members
      |> Map.values()
      |> Enum.map(fn m ->
        %{id: m.id, address: m.address, declared_rps: m.declared_rps, reputation: m.reputation}
      end)

    {:reply, snap, state}
  end

  @impl true
  def handle_cast({:record_success, id}, state) do
    case Map.get(state.members, id) do
      nil ->
        {:noreply, state}

      member ->
        new_reputation = min(1.0, member.reputation * @reputation_recovery_factor)
        # Unconditionally clear the floor timer, even if reputation
        # itself hasn't numerically recovered above the floor yet --
        # eviction is about sustained badness with zero successes in
        # between, not a reputation number held below a threshold.
        updated = %{member | reputation: new_reputation, floor_since: nil}
        {:noreply, %{state | members: Map.put(state.members, id, updated)}}
    end
  end

  @impl true
  def handle_info(:heartbeat_sweep, state) do
    now = System.monotonic_time(:millisecond)

    stale =
      state.members
      |> Map.values()
      |> Enum.filter(fn m ->
        m.heartbeat_interval_ms > 0 and
          now - m.last_heartbeat > m.heartbeat_interval_ms * @heartbeat_miss_limit
      end)

    new_state = Enum.reduce(stale, state, fn m, acc -> evict(acc, m) end)

    schedule_heartbeat_sweep()
    {:noreply, new_state}
  end

  # ---- Private ----

  defp evict(state, %PoolMember{id: id, virtual_position: pos}) do
    order = :gb_trees.delete_any({pos, id}, state.order)
    %{state | members: Map.delete(state.members, id), order: order}
  end

  defp schedule_heartbeat_sweep do
    Process.send_after(self(), :heartbeat_sweep, @heartbeat_sweep_ms)
  end
end
