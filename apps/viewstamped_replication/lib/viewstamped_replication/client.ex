defmodule ViewstampedReplication.Client do
  @moduledoc """
  Stateful VSR client session with monotonic request numbers and retries.

  A session permits one outstanding command. Keeping the process alive keeps
  its client identity and request sequence stable across replica failover.
  """

  use GenServer

  alias ViewstampedReplication.{Replica, Request}
  alias ViewstampedReplication.Reply

  @enforce_keys [:group_id, :client_id, :replicas]
  defstruct [
    :group_id,
    :client_id,
    :replicas,
    :believed_primary,
    :pending,
    request_number: 0,
    retry_timeout: 100
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @spec command(pid(), term(), keyword()) :: {:ok, term()} | {:error, term()}
  def command(client, operation, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    group_id = Keyword.get(opts, :group_id)
    GenServer.call(client, {:command, group_id, operation, timeout}, timeout + 100)
  end

  @spec status(pid()) :: map()
  def status(client), do: GenServer.call(client, :status)

  @impl true
  def init(opts) do
    with {:ok, group_id} <- Keyword.fetch(opts, :group_id),
         {:ok, client_id} <- Keyword.fetch(opts, :client_id),
         {:ok, replicas} <- Keyword.fetch(opts, :replicas),
         true <- (is_list(replicas) and replicas != []) or {:error, :replicas_required} do
      replicas = Enum.map(replicas, &normalize_replica(&1, group_id))

      {:ok,
       %__MODULE__{
         group_id: group_id,
         client_id: client_id,
         replicas: replicas,
         believed_primary: normalize_primary(Keyword.get(opts, :primary), group_id),
         request_number: Keyword.get(opts, :request_number, 0),
         retry_timeout: Keyword.get(opts, :retry_timeout, 100)
       }}
    else
      :error -> {:stop, :client_identity_and_replicas_required}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       group_id: state.group_id,
       client_id: state.client_id,
       request_number: state.request_number,
       believed_primary: state.believed_primary,
       command_in_progress?: not is_nil(state.pending)
     }, state}
  end

  def handle_call({:command, group_id, _operation, _timeout}, _from, state)
      when not is_nil(group_id) and group_id != state.group_id do
    {:reply, {:error, :group_mismatch}, state}
  end

  def handle_call({:command, _group_id, _operation, _timeout}, _from, %{pending: pending} = state)
      when not is_nil(pending) do
    {:reply, {:error, :command_in_progress}, state}
  end

  def handle_call({:command, _group_id, operation, timeout}, from, state)
      when is_integer(timeout) and timeout > 0 do
    request_number = state.request_number + 1

    request = %Request{
      client_id: state.client_id,
      request_number: request_number,
      operation: operation
    }

    reference = make_ref()
    deadline_timer = Process.send_after(self(), {:command_deadline, reference}, timeout)

    pending = %{
      from: from,
      request: request,
      reference: reference,
      retry_timer: nil,
      deadline_timer: deadline_timer,
      target_index: initial_target_index(state)
    }

    state = %{state | request_number: request_number, pending: pending}
    {:noreply, send_pending(state)}
  end

  @impl true
  def handle_info(
        {:vsr_reply, reference,
         %Reply{
           status: :error,
           client_id: client_id,
           request_number: request_number,
           result: result
         }},
        %{pending: %{reference: reference, request: request} = pending} = state
      )
      when client_id == request.client_id and request_number == request.request_number do
    handle_protocol_error(state, pending, result)
  end

  def handle_info(
        {:vsr_reply, reference,
         %Reply{
           status: :ok,
           client_id: client_id,
           request_number: request_number
         } = reply},
        %{pending: %{reference: reference, request: request} = pending} = state
      )
      when client_id == request.client_id and request_number == request.request_number do
    cancel_pending_timers(pending)
    GenServer.reply(pending.from, {:ok, reply.result})

    primary_index = rem(reply.view_number, length(state.replicas))

    {:noreply,
     %{
       state
       | pending: nil,
         believed_primary: Enum.at(state.replicas, primary_index)
     }}
  end

  def handle_info({:vsr_reply, _reference, %Reply{}}, state), do: {:noreply, state}

  def handle_info(
        {:retry_request, reference},
        %{pending: %{reference: reference} = pending} = state
      ) do
    pending = %{pending | target_index: rem(pending.target_index + 1, length(state.replicas))}
    {:noreply, send_pending(%{state | pending: pending})}
  end

  def handle_info({:retry_request, _stale_reference}, state), do: {:noreply, state}

  def handle_info(
        {:command_deadline, reference},
        %{pending: %{reference: reference} = pending} = state
      ) do
    cancel_timer(pending.retry_timer)
    GenServer.reply(pending.from, {:error, :quorum_unavailable})
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:command_deadline, _stale_reference}, state), do: {:noreply, state}

  defp send_pending(%{pending: pending} = state) do
    target = Enum.at(state.replicas, pending.target_index)
    route = {:client, self(), pending.reference}
    :ok = Replica.submit(target, route, pending.request)

    cancel_timer(pending.retry_timer)

    retry_timer =
      Process.send_after(self(), {:retry_request, pending.reference}, state.retry_timeout)

    %{state | pending: %{pending | retry_timer: retry_timer}}
  end

  defp initial_target_index(%{believed_primary: nil}), do: 0

  defp initial_target_index(state) do
    Enum.find_index(state.replicas, &(&1 == state.believed_primary)) || 0
  end

  defp cancel_pending_timers(pending) do
    cancel_timer(pending.retry_timer)
    cancel_timer(pending.deadline_timer)
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(reference), do: Process.cancel_timer(reference)

  defp handle_protocol_error(state, pending, {:error, {:not_primary, primary_id}}) do
    believed_primary = normalize_replica(primary_id, state.group_id)

    case Enum.find_index(state.replicas, &(&1 == believed_primary)) do
      nil ->
        {:noreply, state}

      target_index ->
        pending = %{pending | target_index: target_index}
        {:noreply, send_pending(%{state | believed_primary: believed_primary, pending: pending})}
    end
  end

  defp handle_protocol_error(state, pending, {:error, :stale_request}) do
    cancel_pending_timers(pending)
    GenServer.reply(pending.from, {:error, :stale_request})
    {:noreply, %{state | pending: nil}}
  end

  defp handle_protocol_error(state, _pending, _retryable_error), do: {:noreply, state}

  defp normalize_replica(pid, _group_id) when is_pid(pid), do: pid
  defp normalize_replica({group_id, replica_id}, _group_id), do: {group_id, replica_id}
  defp normalize_replica(replica_id, group_id), do: {group_id, replica_id}

  defp normalize_primary(nil, _group_id), do: nil
  defp normalize_primary(primary, group_id), do: normalize_replica(primary, group_id)
end
