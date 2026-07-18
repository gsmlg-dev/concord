defmodule ViewstampedReplication.Test.Simulator do
  @moduledoc false

  alias ViewstampedReplication.{
    ApplyMetadata,
    Configuration,
    Log,
    Member,
    Request
  }

  alias ViewstampedReplication.Protocol
  alias ViewstampedReplication.Protocol.{Envelope, PrepareOk, State}
  alias ViewstampedReplication.Test.{Network, RegisterStateMachine}

  defmodule Message do
    @moduledoc false
    @enforce_keys [:id, :from, :to, :envelope]
    defstruct [:id, :from, :to, :envelope, delay: 0]

    @type t :: %__MODULE__{
            id: pos_integer(),
            from: term(),
            to: term(),
            envelope: Envelope.t(),
            delay: non_neg_integer()
          }
  end

  defmodule Timer do
    @moduledoc false
    @enforce_keys [:id, :replica_id, :kind, :token, :timeout]
    defstruct [:id, :replica_id, :kind, :token, :timeout]

    @type t :: %__MODULE__{
            id: pos_integer(),
            replica_id: term(),
            kind: atom(),
            token: term(),
            timeout: non_neg_integer()
          }
  end

  defmodule ClientReply do
    @moduledoc false
    @enforce_keys [:id, :from, :to, :reply]
    defstruct [:id, :from, :to, :reply, delay: 0]

    @type t :: %__MODULE__{
            id: pos_integer(),
            from: term(),
            to: term(),
            reply: ViewstampedReplication.Reply.t(),
            delay: non_neg_integer()
          }
  end

  defstruct replicas: %{},
            clients: %{},
            message_queue: [],
            timer_queue: [],
            crashed: MapSet.new(),
            network: nil,
            history: [],
            applied_history: %{},
            snapshot_bases: %{},
            machine_states: %{},
            state_machine: RegisterStateMachine,
            state_machine_options: [],
            seed: 0,
            next_id: 1,
            step: 0

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)
    state_machine = Keyword.get(opts, :state_machine, RegisterStateMachine)
    state_machine_options = Keyword.get(opts, :state_machine_options, [])

    replicas =
      case Keyword.fetch(opts, :replicas) do
        {:ok, replicas} -> replicas
        :error -> build_replicas(opts)
      end

    machine_states =
      Map.new(replicas, fn {replica_id, _state} ->
        {replica_id, state_machine.init(state_machine_options)}
      end)

    %__MODULE__{
      replicas: replicas,
      network: Network.new(),
      machine_states: machine_states,
      state_machine: state_machine,
      state_machine_options: state_machine_options,
      seed: seed
    }
    |> assert_safety!()
  end

  @spec submit_client_request(t(), term(), Request.t()) :: t()
  def submit_client_request(%__MODULE__{} = simulator, replica_id, %Request{} = request) do
    submit_client_request(simulator, replica_id, {:client, request.client_id}, request)
  end

  @spec submit_client_request(t(), term(), term(), Request.t()) :: t()
  def submit_client_request(
        %__MODULE__{} = simulator,
        replica_id,
        client_route,
        %Request{} = request
      ) do
    call_id = {request.client_id, request.request_number}

    simulator
    |> put_client_request(request, replica_id)
    |> record_invocation_or_retry(call_id, client_route, replica_id, request)
    |> transition(replica_id, {:client_request, client_route, request})
  end

  @spec deliver_message(t()) :: t()
  def deliver_message(%__MODULE__{} = simulator), do: deliver_message(simulator, :next)

  @spec deliver_message(
          t(),
          :next | pos_integer() | (Message.t() | ClientReply.t() -> boolean())
        ) :: t()
  def deliver_message(%__MODULE__{} = simulator, selector) do
    with {:ok, message} <- select_message(simulator.message_queue, selector),
         true <- deliverable?(simulator, message) do
      simulator
      |> remove_message(message.id)
      |> deliver_queued(message)
    else
      :error -> simulator
      false -> record(simulator, %{type: :message_blocked, selector: selector})
    end
  end

  @spec drop_message(t()) :: t()
  def drop_message(%__MODULE__{} = simulator), do: drop_message(simulator, :next)

  @spec drop_message(
          t(),
          :next | pos_integer() | (Message.t() | ClientReply.t() -> boolean())
        ) :: t()
  def drop_message(%__MODULE__{} = simulator, selector) do
    case select_message(simulator.message_queue, selector) do
      {:ok, message} ->
        simulator
        |> remove_message(message.id)
        |> record(%{
          type: :message_dropped,
          message_id: message.id,
          from: message.from,
          to: message.to
        })
        |> assert_safety!()

      :error ->
        simulator
    end
  end

  @spec duplicate_message(t()) :: t()
  def duplicate_message(%__MODULE__{} = simulator), do: duplicate_message(simulator, :next)

  @spec duplicate_message(
          t(),
          :next | pos_integer() | (Message.t() | ClientReply.t() -> boolean())
        ) :: t()
  def duplicate_message(%__MODULE__{} = simulator, selector) do
    case select_message(simulator.message_queue, selector) do
      {:ok, message} ->
        {copy, next_simulator} = duplicate_queued(simulator, message)

        %{next_simulator | message_queue: next_simulator.message_queue ++ [copy]}
        |> record(%{type: :message_duplicated, message_id: message.id, copy_id: copy.id})
        |> assert_safety!()

      :error ->
        simulator
    end
  end

  @spec delay_message(t(), non_neg_integer()) :: t()
  def delay_message(%__MODULE__{} = simulator, delay),
    do: delay_message(simulator, :next, delay)

  @spec delay_message(
          t(),
          :next | pos_integer() | (Message.t() | ClientReply.t() -> boolean()),
          non_neg_integer()
        ) :: t()
  def delay_message(%__MODULE__{} = simulator, selector, delay)
      when is_integer(delay) and delay >= 0 do
    case select_message(simulator.message_queue, selector) do
      {:ok, message} ->
        queue =
          Enum.map(simulator.message_queue, fn queued ->
            if queued.id == message.id,
              do: Map.update!(queued, :delay, &(&1 + delay)),
              else: queued
          end)

        %{simulator | message_queue: queue}
        |> record(%{type: :message_delayed, message_id: message.id, delay: delay})
        |> assert_safety!()

      :error ->
        simulator
    end
  end

  @spec partition(t(), term() | [term()], term() | [term()]) :: t()
  def partition(%__MODULE__{} = simulator, left, right) do
    %{simulator | network: Network.partition(simulator.network, left, right)}
    |> record(%{type: :partition, left: List.wrap(left), right: List.wrap(right)})
    |> assert_safety!()
  end

  @spec heal_partition(t()) :: t()
  def heal_partition(%__MODULE__{} = simulator) do
    %{simulator | network: Network.heal(simulator.network)}
    |> record(%{type: :partition_healed, scope: :all})
    |> assert_safety!()
  end

  @spec heal_partition(t(), term() | [term()], term() | [term()]) :: t()
  def heal_partition(%__MODULE__{} = simulator, left, right) do
    %{simulator | network: Network.heal(simulator.network, left, right)}
    |> record(%{type: :partition_healed, left: List.wrap(left), right: List.wrap(right)})
    |> assert_safety!()
  end

  @spec crash_replica(t(), term()) :: t()
  def crash_replica(%__MODULE__{} = simulator, replica_id) do
    %{simulator | crashed: MapSet.put(simulator.crashed, replica_id)}
    |> record(%{type: :replica_crashed, replica_id: replica_id})
    |> assert_safety!()
  end

  @spec restart_replica(t(), term(), keyword()) :: t()
  def restart_replica(%__MODULE__{} = simulator, replica_id, opts \\ []) do
    previous = Map.fetch!(simulator.replicas, replica_id)

    state =
      Keyword.get_lazy(opts, :state, fn ->
        State.new(previous.configuration)
      end)

    machine_state =
      Keyword.get_lazy(opts, :machine_state, fn ->
        simulator.state_machine.init(simulator.state_machine_options)
      end)

    %{
      simulator
      | replicas: Map.put(simulator.replicas, replica_id, state),
        crashed: MapSet.delete(simulator.crashed, replica_id),
        machine_states: Map.put(simulator.machine_states, replica_id, machine_state),
        applied_history: Map.delete(simulator.applied_history, replica_id),
        snapshot_bases: Map.delete(simulator.snapshot_bases, replica_id)
    }
    |> record(%{type: :replica_restarted, replica_id: replica_id})
    |> assert_safety!()
  end

  @spec recover_storage(t(), term(), term()) :: t()
  def recover_storage(%__MODULE__{} = simulator, replica_id, recovered \\ :empty) do
    transition(simulator, replica_id, {:storage_recovered, recovered})
  end

  @spec complete_snapshot(t(), term(), non_neg_integer(), term()) :: t()
  def complete_snapshot(%__MODULE__{} = simulator, replica_id, op_number, snapshot) do
    transition(simulator, replica_id, {:snapshot_completed, op_number, snapshot})
  end

  @spec fire_timer(t(), term(), atom()) :: t()
  def fire_timer(%__MODULE__{} = simulator, replica_id, kind) do
    fire_timer(simulator, fn timer -> timer.replica_id == replica_id and timer.kind == kind end)
  end

  @spec fire_timer(t(), pos_integer() | (Timer.t() -> boolean())) :: t()
  def fire_timer(%__MODULE__{} = simulator, selector) do
    case select_timer(simulator.timer_queue, selector) do
      {:ok, timer} ->
        simulator
        |> remove_timer(timer.id)
        |> record(%{
          type: :timer_fired,
          timer_id: timer.id,
          replica_id: timer.replica_id,
          kind: timer.kind,
          token: timer.token
        })
        |> transition(timer.replica_id, {:timeout, timer.kind, timer.token})

      :error ->
        simulator
    end
  end

  @spec deliver_all(t(), non_neg_integer()) :: t()
  def deliver_all(simulator, limit \\ 10_000)

  def deliver_all(%__MODULE__{} = simulator, 0), do: simulator
  def deliver_all(%__MODULE__{message_queue: []} = simulator, _limit), do: simulator

  def deliver_all(%__MODULE__{} = simulator, limit) do
    case Enum.find(
           simulator.message_queue,
           &(deliverable?(simulator, &1) and &1.delay == 0)
         ) do
      nil -> simulator
      message -> simulator |> deliver_message(message.id) |> deliver_all(limit - 1)
    end
  end

  @spec assert_safety!(t()) :: t()
  def assert_safety!(%__MODULE__{} = simulator) do
    try do
      Enum.each(simulator.replicas, fn {_replica_id, state} ->
        Protocol.assert_invariants!(state)
      end)

      assert_committed_prefixes!(simulator)
      assert_applied_histories!(simulator)
      assert_snapshot_consistency!(simulator)
      assert_normal_commits_had_quorum!(simulator)
      simulator
    rescue
      exception ->
        reraise RuntimeError,
                [
                  message:
                    "simulator safety failure (seed=#{inspect(simulator.seed)}): " <>
                      Exception.message(exception)
                ],
                __STACKTRACE__
    end
  end

  @spec messages(t(), (Message.t() | ClientReply.t() -> boolean())) ::
          [Message.t() | ClientReply.t()]
  def messages(%__MODULE__{} = simulator, predicate \\ fn _message -> true end) do
    Enum.filter(simulator.message_queue, predicate)
  end

  defp build_replicas(opts) do
    replica_ids = Keyword.get(opts, :replica_ids, [1, 2, 3])
    group_id = Keyword.get(opts, :group_id, :test_group)
    status = Keyword.get(opts, :status, :normal)
    members = Enum.map(replica_ids, &%Member{id: &1, endpoint: {:simulator, &1}})

    Map.new(replica_ids, fn replica_id ->
      configuration =
        Configuration.new!(group_id: group_id, replica_id: replica_id, members: members)

      {replica_id, %{State.new(configuration) | status: status}}
    end)
  end

  defp transition(%__MODULE__{} = simulator, replica_id, event) do
    if MapSet.member?(simulator.crashed, replica_id) do
      record(simulator, %{type: :event_ignored_crashed, replica_id: replica_id, event: event})
    else
      previous = Map.fetch!(simulator.replicas, replica_id)
      {current, effects} = protocol_step!(simulator, previous, event)

      %{simulator | replicas: Map.put(simulator.replicas, replica_id, current)}
      |> record(%{type: :transition, replica_id: replica_id, event: event, effects: effects})
      |> record_commit_advances(replica_id, previous, current)
      |> interpret_effects(replica_id, effects)
      |> assert_safety!()
    end
  end

  defp interpret_effects(simulator, _replica_id, []), do: simulator

  defp interpret_effects(simulator, replica_id, [effect | remaining]) do
    simulator
    |> interpret_effect(replica_id, effect)
    |> interpret_effects(replica_id, remaining)
  end

  defp interpret_effect(simulator, _replica_id, {:send, to, %Envelope{} = envelope}) do
    enqueue_message(simulator, envelope.from, to, envelope)
  end

  defp interpret_effect(simulator, replica_id, {:broadcast, %Envelope{} = envelope}) do
    simulator.replicas
    |> Map.keys()
    |> Enum.reject(&(&1 == replica_id))
    |> Enum.reduce(simulator, fn to, acc ->
      enqueue_message(acc, envelope.from, to, envelope)
    end)
  end

  defp interpret_effect(simulator, replica_id, {:reply, route, reply}) do
    {queued_reply, next_simulator} =
      new_client_reply(simulator, replica_id, route, reply)

    %{next_simulator | message_queue: next_simulator.message_queue ++ [queued_reply]}
  end

  defp interpret_effect(simulator, replica_id, {:apply, entry}) do
    metadata = %ApplyMetadata{
      group_id: Map.fetch!(simulator.replicas, replica_id).group_id,
      view_number: entry.view_number,
      op_number: entry.op_number,
      client_id: entry.client_id,
      request_number: entry.request_number,
      entry_metadata: entry.metadata
    }

    machine_state = Map.fetch!(simulator.machine_states, replica_id)

    {result, next_machine_state} =
      simulator.state_machine.apply(metadata, entry.operation, machine_state)

    simulator
    |> Map.update!(:machine_states, &Map.put(&1, replica_id, next_machine_state))
    |> Map.update!(:applied_history, fn histories ->
      Map.update(histories, replica_id, [{entry, result}], &[{entry, result} | &1])
    end)
    |> record(%{
      type: :state_machine_applied,
      replica_id: replica_id,
      entry: entry,
      result: result
    })
    |> transition(replica_id, {:state_machine_applied, entry.op_number, result})
  end

  defp interpret_effect(simulator, replica_id, {:schedule_timer, kind, timeout, token}) do
    {timer, next_simulator} =
      new_timer(simulator, replica_id, kind, timeout, token)

    timers =
      next_simulator.timer_queue
      |> Enum.reject(&(&1.replica_id == replica_id and &1.kind == kind))
      |> Kernel.++([timer])

    %{next_simulator | timer_queue: timers}
  end

  defp interpret_effect(simulator, replica_id, {:cancel_timer, kind}) do
    timers =
      Enum.reject(
        simulator.timer_queue,
        &(&1.replica_id == replica_id and &1.kind == kind)
      )

    %{simulator | timer_queue: timers}
  end

  defp interpret_effect(simulator, replica_id, {:persist, {:install_snapshot, snapshot}}) do
    state_machine_snapshot =
      case snapshot do
        %{state_machine: value} -> value
        value -> value
      end

    case simulator.state_machine.restore(state_machine_snapshot) do
      {:ok, machine_state} ->
        snapshot_op_number = Map.fetch!(simulator.replicas, replica_id).applied_number

        simulator
        |> Map.update!(:machine_states, &Map.put(&1, replica_id, machine_state))
        |> Map.update!(:applied_history, &Map.delete(&1, replica_id))
        |> Map.update!(:snapshot_bases, &Map.put(&1, replica_id, snapshot_op_number))
        |> record(%{
          type: :snapshot_installed,
          replica_id: replica_id,
          snapshot_op_number: snapshot_op_number,
          snapshot: snapshot
        })

      {:error, reason} ->
        raise "simulator snapshot restore failed (seed=#{inspect(simulator.seed)}): " <>
                inspect(reason)
    end
  end

  defp interpret_effect(simulator, replica_id, {:persist, {:write_snapshot, snapshot}}) do
    snapshot_op_number = Map.fetch!(simulator.replicas, replica_id).snapshot_op_number

    remaining_history =
      simulator.applied_history
      |> Map.get(replica_id, [])
      |> Enum.reject(fn {entry, _result} -> entry.op_number <= snapshot_op_number end)

    simulator
    |> Map.update!(:applied_history, &Map.put(&1, replica_id, remaining_history))
    |> Map.update!(:snapshot_bases, &Map.put(&1, replica_id, snapshot_op_number))
    |> record(%{
      type: :snapshot_written,
      replica_id: replica_id,
      snapshot_op_number: snapshot_op_number,
      snapshot: snapshot
    })
  end

  defp interpret_effect(simulator, replica_id, effect) do
    record(simulator, %{type: :effect, replica_id: replica_id, effect: effect})
  end

  defp enqueue_message(simulator, from, to, envelope) do
    {message, next_simulator} = new_message(simulator, from, to, envelope, 0)
    %{next_simulator | message_queue: next_simulator.message_queue ++ [message]}
  end

  defp new_message(simulator, from, to, envelope, delay) do
    message = %Message{
      id: simulator.next_id,
      from: from,
      to: to,
      envelope: envelope,
      delay: delay
    }

    {message, %{simulator | next_id: simulator.next_id + 1}}
  end

  defp new_timer(simulator, replica_id, kind, timeout, token) do
    timer = %Timer{
      id: simulator.next_id,
      replica_id: replica_id,
      kind: kind,
      timeout: timeout,
      token: token
    }

    {timer, %{simulator | next_id: simulator.next_id + 1}}
  end

  defp new_client_reply(simulator, from, to, reply) do
    queued_reply = %ClientReply{
      id: simulator.next_id,
      from: from,
      to: to,
      reply: reply
    }

    {queued_reply, %{simulator | next_id: simulator.next_id + 1}}
  end

  defp duplicate_queued(simulator, %Message{} = message) do
    new_message(simulator, message.from, message.to, message.envelope, message.delay)
  end

  defp duplicate_queued(simulator, %ClientReply{} = reply) do
    {copy, next_simulator} = new_client_reply(simulator, reply.from, reply.to, reply.reply)
    {%{copy | delay: reply.delay}, next_simulator}
  end

  defp select_message([], _selector), do: :error
  defp select_message([message | _], :next), do: {:ok, message}

  defp select_message(messages, id) when is_integer(id),
    do: fetch_selected(messages, &(&1.id == id))

  defp select_message(messages, predicate) when is_function(predicate, 1),
    do: fetch_selected(messages, predicate)

  defp select_timer(timers, id) when is_integer(id),
    do: fetch_selected(timers, &(&1.id == id))

  defp select_timer(timers, predicate) when is_function(predicate, 1),
    do: fetch_selected(timers, predicate)

  defp fetch_selected(enumerable, predicate) do
    case Enum.find(enumerable, predicate) do
      nil -> :error
      item -> {:ok, item}
    end
  end

  defp remove_message(simulator, id) do
    %{simulator | message_queue: Enum.reject(simulator.message_queue, &(&1.id == id))}
  end

  defp remove_timer(simulator, id) do
    %{simulator | timer_queue: Enum.reject(simulator.timer_queue, &(&1.id == id))}
  end

  defp deliverable?(_simulator, %ClientReply{}), do: true

  defp deliverable?(simulator, %Message{} = message) do
    not MapSet.member?(simulator.crashed, message.to) and
      Network.connected?(simulator.network, message.from, message.to)
  end

  defp deliver_queued(simulator, %Message{} = message) do
    simulator
    |> record(%{
      type: :message_delivered,
      message_id: message.id,
      from: message.from,
      to: message.to,
      envelope: message.envelope
    })
    |> record_prepare_ok(message)
    |> transition(message.to, {:peer_message, message.from, message.envelope})
  end

  defp deliver_queued(simulator, %ClientReply{} = queued_reply) do
    reply = queued_reply.reply
    client = Map.get(simulator.clients, reply.client_id, %{})

    if match?(
         %{last_reply: %{request_number: request_number}}
         when request_number == reply.request_number,
         client
       ) do
      record(simulator, %{
        type: :duplicate_reply_discarded,
        call_id: {reply.client_id, reply.request_number},
        message_id: queued_reply.id
      })
    else
      simulator
      |> record(%{
        type: :complete,
        call_id: {reply.client_id, reply.request_number},
        client_id: reply.client_id,
        request_number: reply.request_number,
        result: reply.result,
        route: queued_reply.to,
        replica_id: queued_reply.from,
        message_id: queued_reply.id
      })
      |> update_client_reply(reply)
    end
  end

  defp put_client_request(simulator, request, replica_id) do
    client =
      simulator.clients
      |> Map.get(request.client_id, %{})
      |> Map.merge(%{
        request_number: request.request_number,
        outstanding: request,
        believed_primary: replica_id
      })

    %{simulator | clients: Map.put(simulator.clients, request.client_id, client)}
  end

  defp record_invocation_or_retry(simulator, call_id, route, replica_id, request) do
    type =
      if Enum.any?(simulator.history, &(&1.type == :invoke and &1.call_id == call_id)),
        do: :retry,
        else: :invoke

    record(simulator, %{
      type: type,
      call_id: call_id,
      client_id: request.client_id,
      request_number: request.request_number,
      operation: request.operation,
      route: route,
      replica_id: replica_id
    })
  end

  defp update_client_reply(simulator, reply) do
    clients =
      Map.update(simulator.clients, reply.client_id, %{last_reply: reply}, fn client ->
        client
        |> Map.put(:last_reply, reply)
        |> Map.put(:outstanding, nil)
      end)

    %{simulator | clients: clients}
  end

  defp record_prepare_ok(
         simulator,
         %Message{
           from: from,
           to: to,
           envelope: %Envelope{payload: %PrepareOk{view_number: view, op_number: op}}
         }
       ) do
    record(simulator, %{
      type: :prepare_ok_delivered,
      from: from,
      to: to,
      view_number: view,
      op_number: op
    })
  end

  defp record_prepare_ok(simulator, _message), do: simulator

  defp record_commit_advances(simulator, _replica_id, previous, current)
       when current.commit_number == previous.commit_number,
       do: simulator

  defp record_commit_advances(simulator, replica_id, previous, current) do
    primary_id = Configuration.primary_id(current.configuration, current.view_number)

    if replica_id == primary_id do
      Enum.reduce((previous.commit_number + 1)..current.commit_number, simulator, fn
        op_number, acc ->
          case Log.fetch(current.log, op_number) do
            {:ok, %{view_number: view_number}} when view_number == current.view_number ->
              acknowledgers =
                acc.history
                |> Enum.filter(fn
                  %{
                    type: :prepare_ok_delivered,
                    to: ^replica_id,
                    view_number: ack_view,
                    op_number: ^op_number
                  } ->
                    ack_view == current.view_number

                  _event ->
                    false
                end)
                |> Enum.map(& &1.from)
                |> MapSet.new()
                |> MapSet.put(replica_id)

              record(acc, %{
                type: :normal_commit,
                replica_id: replica_id,
                view_number: current.view_number,
                op_number: op_number,
                acknowledgers: acknowledgers,
                quorum_size: Configuration.quorum_size(current.configuration)
              })

            _compacted_or_prior_view ->
              acc
          end
      end)
    else
      simulator
    end
  end

  defp record(simulator, event) do
    entry = Map.merge(event, %{step: simulator.step, seed: simulator.seed})
    %{simulator | history: simulator.history ++ [entry], step: simulator.step + 1}
  end

  defp assert_committed_prefixes!(simulator) do
    committed =
      for {replica_id, state} <- simulator.replicas,
          op_number <- positive_range(state.commit_number),
          {:ok, entry} <- [Log.fetch(state.log, op_number)],
          do: {{replica_id, op_number}, entry}

    committed
    |> Enum.group_by(fn {{_replica_id, op_number}, _entry} -> op_number end, fn {_key, entry} ->
      entry
    end)
    |> Enum.each(fn {op_number, entries} ->
      case Enum.uniq(entries) do
        [_entry] -> :ok
        _entries -> raise "distinct committed operations at position #{op_number}"
      end
    end)
  end

  defp assert_applied_histories!(simulator) do
    Enum.each(simulator.applied_history, fn {replica_id, reverse_history} ->
      state = Map.fetch!(simulator.replicas, replica_id)
      history = Enum.reverse(reverse_history)
      op_numbers = Enum.map(history, fn {entry, _result} -> entry.op_number end)
      snapshot_base = Map.get(simulator.snapshot_bases, replica_id, 0)

      unless op_numbers == operation_range(snapshot_base + 1, snapshot_base + length(op_numbers)) do
        raise "replica #{inspect(replica_id)} did not apply operations in order"
      end

      requests =
        Enum.map(history, fn {entry, _result} -> {entry.client_id, entry.request_number} end)

      unless MapSet.size(MapSet.new(requests)) == length(requests) do
        raise "replica #{inspect(replica_id)} applied one client request more than once"
      end

      Enum.each(history, fn {entry, _result} ->
        unless entry.op_number <= state.commit_number and
                 Log.fetch(state.log, entry.op_number) == {:ok, entry} do
          raise "replica #{inspect(replica_id)} applied an uncommitted operation"
        end
      end)
    end)

    applied_operations =
      Map.new(simulator.applied_history, fn {replica_id, history} ->
        operations =
          history
          |> Enum.reverse()
          |> Map.new(fn {entry, _result} -> {entry.op_number, entry} end)

        {replica_id, operations}
      end)

    for {left_id, left} <- applied_operations,
        {right_id, right} <- applied_operations,
        left_id < right_id do
      common_op_numbers =
        left
        |> Map.keys()
        |> MapSet.new()
        |> MapSet.intersection(Map.keys(right) |> MapSet.new())

      Enum.each(common_op_numbers, fn op_number ->
        unless Map.fetch!(left, op_number) == Map.fetch!(right, op_number) do
          raise "replicas #{inspect(left_id)} and #{inspect(right_id)} applied different operations"
        end
      end)
    end
  end

  defp assert_normal_commits_had_quorum!(simulator) do
    Enum.each(simulator.history, fn
      %{type: :normal_commit, acknowledgers: acknowledgers, quorum_size: quorum_size} ->
        unless MapSet.size(acknowledgers) >= quorum_size do
          raise "a primary committed without a quorum in its view"
        end

      _event ->
        :ok
    end)
  end

  defp assert_snapshot_consistency!(simulator) do
    snapshots =
      simulator.replicas
      |> Enum.filter(fn {_replica_id, state} -> not is_nil(state.snapshot) end)
      |> Enum.group_by(
        fn {_replica_id, state} -> state.snapshot_op_number end,
        fn {_replica_id, state} -> state.snapshot end
      )

    Enum.each(simulator.replicas, fn
      {_replica_id, %{snapshot: nil, snapshot_op_number: 0}} ->
        :ok

      {replica_id, state} when not is_nil(state.snapshot) ->
        unless state.snapshot_op_number <= state.applied_number and
                 state.log.base_op_number == state.snapshot_op_number do
          raise "replica #{inspect(replica_id)} has inconsistent snapshot metadata"
        end

      {replica_id, _state} ->
        raise "replica #{inspect(replica_id)} has a snapshot position without a snapshot"
    end)

    Enum.each(snapshots, fn {op_number, values} ->
      unless length(Enum.uniq(values)) == 1 do
        raise "replicas have different snapshots at operation #{op_number}"
      end
    end)
  end

  defp protocol_step!(simulator, previous, event) do
    try do
      {current, effects} = Protocol.step(previous, event)
      {Protocol.assert_transition!(previous, current), effects}
    rescue
      exception ->
        reraise RuntimeError,
                [
                  message:
                    "simulator transition failure (seed=#{inspect(simulator.seed)}): " <>
                      Exception.message(exception)
                ],
                __STACKTRACE__
    end
  end

  defp positive_range(0), do: []
  defp positive_range(number), do: Enum.to_list(1..number)

  defp operation_range(first, last) when first > last, do: []
  defp operation_range(first, last), do: Enum.to_list(first..last)
end
