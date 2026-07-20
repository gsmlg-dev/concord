defmodule ViewstampedReplication.Replica do
  @moduledoc """
  Supervised effect interpreter for one VSR replica.

  The GenServer is the serialization boundary for protocol state. Storage and
  transport adapters remain process-free and their state is owned here.
  """

  use GenServer

  alias ViewstampedReplication.{
    ApplyMetadata,
    Configuration,
    Log,
    LogEntry,
    Member,
    Protocol,
    Telemetry
  }

  alias ViewstampedReplication.Protocol.{Envelope, State}
  alias ViewstampedReplication.Storage.Memory
  alias ViewstampedReplication.Transport.Local

  @enforce_keys [
    :configuration,
    :protocol_state,
    :state_machine,
    :state_machine_state,
    :storage,
    :storage_state,
    :transport,
    :transport_state
  ]
  defstruct [
    :configuration,
    :protocol_state,
    :state_machine,
    :state_machine_state,
    :storage,
    :storage_state,
    :transport,
    :transport_state,
    :bootstrap,
    durable_applied_number: 0,
    timers: %{}
  ]

  @type t :: %__MODULE__{}

  def start_link(opts) do
    %Configuration{group_id: group_id, replica_id: replica_id} =
      Keyword.fetch!(opts, :configuration)

    GenServer.start_link(__MODULE__, opts, name: via_tuple(group_id, replica_id))
  end

  def child_spec(opts) do
    %Configuration{group_id: group_id, replica_id: replica_id} =
      Keyword.fetch!(opts, :configuration)

    %{
      id: {__MODULE__, group_id, replica_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent
    }
  end

  @spec submit(pid() | term(), term(), ViewstampedReplication.Request.t()) :: :ok
  def submit(
        {group_id, %Member{id: replica_id, endpoint: endpoint}},
        route,
        %ViewstampedReplication.Request{} = request
      ) do
    case endpoint do
      pid when is_pid(pid) ->
        submit(pid, route, request)

      endpoint when endpoint == node() ->
        submit({group_id, replica_id}, route, request)

      endpoint when is_atom(endpoint) ->
        if distributed_endpoint?(endpoint) do
          remote_submit(endpoint, group_id, replica_id, route, request)
        else
          submit({group_id, replica_id}, route, request)
        end

      {_name, endpoint_node} when is_atom(endpoint_node) ->
        remote_submit(endpoint_node, group_id, replica_id, route, request)

      %{node: endpoint_node} = remote when is_atom(endpoint_node) ->
        remote_submit(
          endpoint_node,
          group_id,
          Map.get(remote, :replica_id, replica_id),
          route,
          request
        )

      _local_endpoint ->
        submit({group_id, replica_id}, route, request)
    end
  end

  def submit(replica, route, %ViewstampedReplication.Request{} = request) do
    GenServer.cast(server(replica), {:client_request, route, request})
  end

  @spec read(pid() | term(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def read(replica, operation, opts \\ [])

  def read(
        {group_id, %Member{id: replica_id, endpoint: endpoint}},
        operation,
        opts
      ) do
    case endpoint do
      pid when is_pid(pid) ->
        read(pid, operation, opts)

      endpoint when endpoint == node() ->
        read({group_id, replica_id}, operation, opts)

      endpoint when is_atom(endpoint) ->
        if distributed_endpoint?(endpoint) do
          remote_read(endpoint, group_id, replica_id, operation, opts)
        else
          read({group_id, replica_id}, operation, opts)
        end

      {_name, endpoint_node} when is_atom(endpoint_node) ->
        remote_read(endpoint_node, group_id, replica_id, operation, opts)

      %{node: endpoint_node} = remote when is_atom(endpoint_node) ->
        remote_read(
          endpoint_node,
          group_id,
          Map.get(remote, :replica_id, replica_id),
          operation,
          opts
        )

      _local_endpoint ->
        read({group_id, replica_id}, operation, opts)
    end
  end

  def read(replica, operation, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(server(replica), {:linearizable_read, operation}, timeout)
  catch
    :exit, {:timeout, _details} -> {:error, :quorum_unavailable}
    :exit, {:noproc, _details} -> {:error, :not_found}
    :exit, _reason -> {:error, :not_found}
  end

  @spec deliver(term(), term(), Envelope.t()) :: :ok | {:error, :not_found}
  def deliver(group_id, replica_id, %Envelope{} = envelope) do
    case whereis(group_id, replica_id) do
      nil ->
        {:error, :not_found}

      pid ->
        Kernel.send(pid, {:vsr_peer, envelope.from, envelope})
        :ok
    end
  end

  @spec status(term(), term()) :: {:ok, map()} | {:error, :not_found}
  def status(group_id, replica_id) do
    call_if_running(group_id, replica_id, :status)
  end

  @spec primary(term(), term()) :: {:ok, term()} | {:error, :not_found}
  def primary(group_id, replica_id) do
    call_if_running(group_id, replica_id, :primary)
  end

  @spec snapshot(term(), term()) :: :ok | {:error, term()}
  def snapshot(group_id, replica_id) do
    call_if_running(group_id, replica_id, :snapshot)
  end

  @spec whereis(term(), term()) :: pid() | nil
  def whereis(group_id, replica_id) do
    case Registry.lookup(ViewstampedReplication.Registry, {:replica, group_id, replica_id}) do
      [{pid, _value}] when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: nil

      [] ->
        nil
    end
  end

  @impl true
  def init(opts) do
    with %Configuration{} = configuration <- Keyword.fetch!(opts, :configuration),
         {:ok, configuration} <- Configuration.validate(configuration),
         {:ok, storage, storage_state} <- open_storage(configuration, opts) do
      state_machine = Keyword.fetch!(opts, :state_machine)
      state_machine_state = state_machine.init(Keyword.get(opts, :state_machine_opts, []))
      transport_state = transport_state(configuration, opts)
      {transport, transport_state} = transport_state

      register_endpoint(configuration)

      state = %__MODULE__{
        configuration: configuration,
        protocol_state: State.new(configuration),
        state_machine: state_machine,
        state_machine_state: state_machine_state,
        storage: storage,
        storage_state: storage_state,
        transport: transport,
        transport_state: transport_state,
        bootstrap: Keyword.get(opts, :bootstrap, false)
      }

      {:ok, state, {:continue, :recover_storage}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:recover_storage, state) do
    with {:ok, recovered, storage_state} <- state.storage.recover(state.storage_state),
         {:ok, state} <- recover_runtime(%{state | storage_state: storage_state}, recovered) do
      {:noreply, state}
    else
      {:error, reason} -> {:stop, {:storage_recovery_failed, reason}, state}
      {:stop, reason, state} -> {:stop, reason, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    protocol = state.protocol_state

    status = %{
      group_id: protocol.group_id,
      replica_id: protocol.replica_id,
      status: protocol.status,
      view_number: protocol.view_number,
      primary_id: Configuration.primary_id(state.configuration, protocol.view_number),
      op_number: protocol.op_number,
      commit_number: protocol.commit_number,
      applied_number: protocol.applied_number,
      configuration_hash: Configuration.hash(state.configuration)
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:primary, _from, state) do
    {:reply,
     {:ok, Configuration.primary_id(state.configuration, state.protocol_state.view_number)},
     state}
  end

  def handle_call(:snapshot, _from, state) do
    case state.state_machine.snapshot(state.state_machine_state) do
      {:ok, state_machine_snapshot} ->
        snapshot = %{
          last_op_number: state.protocol_state.applied_number,
          state_machine: state_machine_snapshot
        }

        case run_transition(
               state,
               {:snapshot_completed, state.protocol_state.applied_number, snapshot}
             ) do
          {:ok, state} -> {:reply, :ok, state}
          {:stop, reason, state} -> {:stop, reason, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, {:snapshot_failed, reason}}, state}
    end
  end

  def handle_call({:linearizable_read, operation}, from, state) do
    case run_transition(state, {:read_request, from, operation}) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason, state} -> {:stop, reason, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:client_request, route, request}, state) do
    transition(state, {:client_request, route, request})
  end

  @impl true
  def handle_info({:vsr_peer, replica_id, %Envelope{} = envelope}, state) do
    transition(state, {:peer_message, replica_id, envelope})
  end

  def handle_info({:vsr_timeout, kind, token}, state) do
    case Map.get(state.timers, kind) do
      {_reference, ^token} ->
        transition(%{state | timers: Map.delete(state.timers, kind)}, {:timeout, kind, token})

      _stale_or_cancelled ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.timers, fn {_kind, {reference, _token}} ->
      Process.cancel_timer(reference)
    end)

    state.storage.close(state.storage_state)
  end

  defp recover_runtime(%__MODULE__{bootstrap: true} = state, recovered) do
    with true <- empty_storage?(recovered) or {:error, :bootstrap_requires_empty_storage},
         {:ok, state} <- restore_state_machine(state, recovered.snapshot) do
      run_transition(state, {:storage_recovered, {:bootstrap, :crypto.strong_rand_bytes(16)}})
    end
  end

  defp recover_runtime(state, recovered) do
    state = %{
      state
      | durable_applied_number: Map.get(recovered, :applied_number, 0)
    }

    with {:ok, state} <- restore_state_machine(state, recovered.snapshot) do
      event =
        cond do
          empty_storage?(recovered) ->
            {:storage_recovered, {:empty, :crypto.strong_rand_bytes(16)}}

          Map.get(recovered, :durable, false) ->
            {:storage_recovered, {:durable, normalize_recovered(recovered)}}

          true ->
            {:storage_recovered, normalize_recovered(recovered)}
        end

      run_transition(state, event)
    end
  end

  defp transition(state, event) do
    case run_transition(state, event) do
      {:ok, state} -> {:noreply, state}
      {:stop, reason, state} -> {:stop, reason, state}
    end
  end

  defp run_transition(state, event) do
    {protocol_state, effects} = Protocol.step(state.protocol_state, event)
    execute_effects(%{state | protocol_state: protocol_state}, effects)
  end

  defp execute_effects(state, effects) do
    Enum.reduce_while(effects, {:ok, state}, fn effect, {:ok, state} ->
      case execute_effect(state, effect) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:stop, reason, state} -> {:halt, {:stop, reason, state}}
      end
    end)
  end

  defp execute_effect(state, {:send, destination, %Envelope{} = envelope}) do
    case state.transport.send(state.transport_state, destination, envelope) do
      :ok -> {:ok, state}
      {:error, reason} -> emit_transport_error(state, destination, envelope, reason)
    end
  end

  defp execute_effect(state, {:broadcast, %Envelope{} = envelope}) do
    state.configuration.members
    |> Enum.reject(&(&1.id == state.configuration.replica_id))
    |> Enum.reduce_while({:ok, state}, fn member, {:ok, state} ->
      case execute_effect(state, {:send, member.id, envelope}) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:stop, reason, state} -> {:halt, {:stop, reason, state}}
      end
    end)
  end

  defp execute_effect(state, {:reply, route, reply}) do
    deliver_reply(route, reply)
    {:ok, state}
  end

  defp execute_effect(state, {:read_reply, route, result}) do
    GenServer.reply(route, result)
    {:ok, state}
  end

  defp execute_effect(state, {:read, route, operation}) do
    protocol = state.protocol_state

    metadata = %ApplyMetadata{
      group_id: state.configuration.group_id,
      view_number: protocol.view_number,
      op_number: protocol.applied_number,
      client_id: :linearizable_read,
      request_number: 0
    }

    result =
      if function_exported?(state.state_machine, :read, 3) do
        {:ok, state.state_machine.read(metadata, operation, state.state_machine_state)}
      else
        {:error, :read_not_supported}
      end

    GenServer.reply(route, result)
    {:ok, state}
  end

  defp execute_effect(
         state,
         {:persist, {:client_result, _client_id, _request_number, _result}}
       ) do
    persist_applied_state(state)
  end

  defp execute_effect(
         %{durable_applied_number: durable_applied_number} = state,
         {:persist, {:applied, applied_number, _client_table}}
       )
       when applied_number < durable_applied_number do
    {:ok, state}
  end

  defp execute_effect(state, {:persist, {:applied, applied_number, client_table}}) do
    case state.storage.set_applied(state.storage_state, applied_number, client_table) do
      {:ok, storage_state} ->
        Telemetry.execute([:storage, :operation], %{count: 1}, telemetry_metadata(state))

        {:ok,
         %{
           state
           | storage_state: storage_state,
             durable_applied_number: applied_number
         }}

      {:error, reason} ->
        {:stop, {:storage_failed, reason}, state}
    end
  end

  defp execute_effect(state, {:persist, {:install_state, durable_state}}) do
    case state.storage.install_state(state.storage_state, durable_state) do
      {:ok, storage_state} ->
        Telemetry.execute([:storage, :operation], %{count: 1}, telemetry_metadata(state))

        {:ok,
         %{
           state
           | storage_state: storage_state,
             durable_applied_number:
               Map.get(durable_state, :applied_number, state.durable_applied_number)
         }}

      {:error, reason} ->
        {:stop, {:storage_failed, reason}, state}
    end
  end

  defp execute_effect(state, {:persist, {:install_snapshot, snapshot}}) do
    with {:ok, storage_state} <-
           state.storage.install_snapshot(state.storage_state, snapshot),
         {:ok, state} <- restore_state_machine(%{state | storage_state: storage_state}, snapshot) do
      Telemetry.execute([:storage, :operation], %{count: 1}, telemetry_metadata(state))
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:snapshot_install_failed, reason}, state}
    end
  end

  defp execute_effect(state, {:persist, operation}) do
    case persist(state.storage, state.storage_state, operation) do
      {:ok, storage_state} ->
        Telemetry.execute([:storage, :operation], %{count: 1}, telemetry_metadata(state))
        {:ok, %{state | storage_state: storage_state}}

      {:error, reason} ->
        {:stop, {:storage_failed, reason}, state}
    end
  end

  defp execute_effect(state, {:apply, %LogEntry{} = entry}) do
    metadata = %ApplyMetadata{
      group_id: state.configuration.group_id,
      view_number: entry.view_number,
      op_number: entry.op_number,
      client_id: entry.client_id,
      request_number: entry.request_number,
      entry_metadata: entry.metadata
    }

    {result, state_machine_state} =
      state.state_machine.apply(metadata, entry.operation, state.state_machine_state)

    state = %{state | state_machine_state: state_machine_state}
    run_transition(state, {:state_machine_applied, entry.op_number, result})
  end

  defp execute_effect(state, {:schedule_timer, kind, timeout, token})
       when is_integer(timeout) and timeout >= 0 do
    state = cancel_timer(state, kind)
    reference = Process.send_after(self(), {:vsr_timeout, kind, token}, timeout)
    {:ok, %{state | timers: Map.put(state.timers, kind, {reference, token})}}
  end

  defp execute_effect(state, {:cancel_timer, kind}), do: {:ok, cancel_timer(state, kind)}

  defp execute_effect(state, {:request_state_transfer, _replica_id, _range}), do: {:ok, state}

  defp execute_effect(state, {:emit_telemetry, event, measurements, metadata}) do
    Telemetry.execute(
      normalize_event(event),
      measurements,
      Map.merge(telemetry_metadata(state), metadata)
    )

    {:ok, state}
  end

  defp execute_effect(state, effect),
    do: {:stop, {:unsupported_protocol_effect, effect}, state}

  defp persist(storage, storage_state, {:append, entry}),
    do: storage.append(storage_state, entry)

  defp persist(storage, storage_state, {:set_commit_number, commit_number}),
    do: storage.set_commit_number(storage_state, commit_number)

  defp persist(storage, storage_state, {:hard_state, hard_state}),
    do: storage.persist_hard_state(storage_state, hard_state)

  defp persist(storage, storage_state, {:applied, applied_number, client_table}),
    do: storage.set_applied(storage_state, applied_number, client_table)

  defp persist(storage, storage_state, {:install_state, durable_state}),
    do: storage.install_state(storage_state, durable_state)

  defp persist(storage, storage_state, {:truncate_suffix, last_op_number}),
    do: storage.truncate_suffix(storage_state, last_op_number)

  defp persist(storage, storage_state, {:write_snapshot, snapshot}),
    do: storage.write_snapshot(storage_state, snapshot)

  defp persist(storage, storage_state, {:install_snapshot, snapshot}),
    do: storage.install_snapshot(storage_state, snapshot)

  defp persist(_storage, _storage_state, operation),
    do: {:error, {:unsupported_storage_operation, operation}}

  defp open_storage(configuration, opts) do
    {storage, storage_opts} =
      case Keyword.get(opts, :storage, Memory) do
        {module, module_opts} -> {module, module_opts}
        module when is_atom(module) -> {module, Keyword.get(opts, :storage_opts, [])}
      end

    storage_opts =
      Keyword.merge(storage_opts,
        configuration_hash: Configuration.hash(configuration),
        replica_id: configuration.replica_id
      )

    case storage.open(storage_opts) do
      {:ok, storage_state} -> {:ok, storage, storage_state}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transport_state(configuration, opts) do
    endpoints = Map.new(configuration.members, &{&1.id, &1.endpoint})

    case Keyword.get(opts, :transport, Local) do
      {module, transport_state} ->
        {module, transport_state}

      Local ->
        {Local,
         Local.new(
           registry: ViewstampedReplication.Registry,
           endpoints: endpoints
         )}

      module ->
        {module, module.new(endpoints: endpoints)}
    end
  end

  defp normalize_recovered(recovered) do
    hard_state = recovered.hard_state
    {:ok, log} = normalize_log(recovered.log)

    %{
      hard_state: hard_state,
      view_number: Map.get(hard_state, :view_number, 0),
      last_normal_view: Map.get(hard_state, :last_normal_view, 0),
      status: Map.get(hard_state, :status, :recovering),
      op_number: Log.last_op_number(log),
      commit_number: recovered.commit_number,
      applied_number: snapshot_op_number(recovered.snapshot),
      log: log,
      client_table: recovered.client_table,
      snapshot: recovered.snapshot,
      configuration_hash: recovered.configuration_hash,
      replica_id: recovered.replica_id,
      recovery_nonce: :crypto.strong_rand_bytes(16)
    }
  end

  defp empty_storage?(recovered) do
    {:ok, log} = normalize_log(recovered.log)

    recovered.hard_state == %{} and Log.last_op_number(log) == 0 and
      recovered.commit_number == 0 and is_nil(recovered.snapshot)
  end

  defp persist_applied_state(state) do
    protocol = state.protocol_state

    case state.storage.set_applied(
           state.storage_state,
           protocol.applied_number,
           protocol.client_table
         ) do
      {:ok, storage_state} -> {:ok, %{state | storage_state: storage_state}}
      {:error, reason} -> {:stop, {:storage_failed, reason}, state}
    end
  end

  defp restore_state_machine(state, nil), do: {:ok, state}

  defp restore_state_machine(state, snapshot) do
    snapshot =
      case snapshot do
        %{state_machine: state_machine_snapshot} -> state_machine_snapshot
        state_machine_snapshot -> state_machine_snapshot
      end

    case state.state_machine.restore(snapshot) do
      {:ok, state_machine_state} -> {:ok, %{state | state_machine_state: state_machine_state}}
      {:error, reason} -> {:error, {:state_machine_restore_failed, reason}}
    end
  end

  defp snapshot_op_number(nil), do: 0

  defp snapshot_op_number(%{last_op_number: op_number})
       when is_integer(op_number) and op_number >= 0,
       do: op_number

  defp snapshot_op_number(%{op_number: op_number})
       when is_integer(op_number) and op_number >= 0,
       do: op_number

  defp snapshot_op_number(_snapshot), do: 0

  defp normalize_log(%Log{} = log), do: {:ok, log}
  defp normalize_log(entries) when is_list(entries), do: Log.new(entries)

  defp register_endpoint(configuration) do
    endpoint =
      configuration.members
      |> Enum.find(&(&1.id == configuration.replica_id))
      |> Map.fetch!(:endpoint)

    {:ok, _owner} =
      Registry.register(
        ViewstampedReplication.Registry,
        {:endpoint, configuration.group_id, endpoint},
        configuration.replica_id
      )
  end

  defp cancel_timer(state, kind) do
    case Map.pop(state.timers, kind) do
      {nil, timers} ->
        %{state | timers: timers}

      {{reference, _token}, timers} ->
        Process.cancel_timer(reference)
        %{state | timers: timers}
    end
  end

  defp deliver_reply({:client, pid, reference}, reply) when is_pid(pid),
    do: Kernel.send(pid, {:vsr_reply, reference, reply})

  defp deliver_reply(pid, reply) when is_pid(pid),
    do: Kernel.send(pid, {:vsr_reply, reply})

  defp deliver_reply(from, reply) when is_tuple(from), do: GenServer.reply(from, reply)

  defp normalize_event([:viewstamped_replication | event]), do: event
  defp normalize_event(event), do: event

  defp telemetry_metadata(state) do
    protocol = state.protocol_state

    %{
      group_id: protocol.group_id,
      replica_id: protocol.replica_id,
      view_number: protocol.view_number,
      op_number: protocol.op_number,
      commit_number: protocol.commit_number,
      primary_id: Configuration.primary_id(state.configuration, protocol.view_number)
    }
  end

  defp emit_transport_error(state, destination, envelope, reason) do
    Telemetry.execute(
      [:transport, :error],
      %{count: 1},
      Map.merge(telemetry_metadata(state), %{
        destination: destination,
        reason: reason,
        message_type: message_type(envelope.payload)
      })
    )

    {:ok, state}
  end

  defp message_type(%{__struct__: module}) when is_atom(module), do: module
  defp message_type(message) when is_atom(message), do: message
  defp message_type(_message), do: :unknown

  defp server(pid) when is_pid(pid), do: pid
  defp server({group_id, replica_id}), do: via_tuple(group_id, replica_id)

  defp remote_submit(node, group_id, replica_id, route, request) do
    :erpc.cast(node, __MODULE__, :submit, [{group_id, replica_id}, route, request])
  end

  defp remote_read(node, group_id, replica_id, operation, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    :erpc.call(node, __MODULE__, :read, [{group_id, replica_id}, operation, opts], timeout + 100)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp distributed_endpoint?(endpoint) do
    endpoint
    |> Atom.to_string()
    |> String.contains?("@")
  end

  defp call_if_running(group_id, replica_id, request) do
    case whereis(group_id, replica_id) do
      nil ->
        {:error, :not_found}

      pid ->
        try do
          GenServer.call(pid, request)
        catch
          :exit, {:noproc, _details} -> {:error, :not_found}
          :exit, {:normal, _details} -> {:error, :not_found}
        end
    end
  end

  defp via_tuple(group_id, replica_id) do
    {:via, Registry, {ViewstampedReplication.Registry, {:replica, group_id, replica_id}}}
  end
end
