defmodule Concord.Txn do
  @moduledoc """
  Atomic multi-key transactions for Concord.

  A transaction is a one-shot, atomic operation that:
  1. Evaluates compare predicates against pre-transaction state
  2. If all hold (AND), executes the `success` branch
  3. Otherwise, executes the `failure` branch
  4. Returns `{:ok, %Result{}}` — never `{:error, ...}` for compare failures

  ## Transaction Spec

      %{
        compare: [compare()],
        success: [operation()],
        failure: [operation()]
      }

  ## Examples

      # Atomic create-if-absent
      Concord.Txn.commit(%{
        compare: [{:exists, "/key", :==, false}],
        success: [{:put, "/key", value, %{}}],
        failure: [{:get, {:key, "/key"}, %{}}]
      })

      # Conditional update with revision check
      Concord.Txn.commit(%{
        compare: [{:mod_revision, "/key", :==, 1842}],
        success: [{:put, "/key", new_value, %{prev_kv: true}}],
        failure: [{:get, {:key, "/key"}, %{}}]
      })
  """

  alias Concord.Txn.Result
  alias Concord.Validation

  @timeout 5_000
  @cluster_name :concord_cluster

  @doc """
  Commits a transaction spec atomically.

  ## Options

  - `:idempotency_key` — string key for safe retry (optional)
  - `:timeout` — operation timeout in ms (default: 5000)

  ## Returns

  - `{:ok, %Result{succeeded: true, ...}}` — success branch ran
  - `{:ok, %Result{succeeded: false, ...}}` — failure branch ran (not an error)
  - `{:error, {:invalid_txn, reason}}` — spec validation failed
  - `{:error, reason}` — cluster error (:no_leader, :timeout, etc.)
  """
  @spec commit(map(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def commit(spec, opts \\ []) do
    with :ok <- Validation.validate_txn_spec(spec) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      idempotency_key = Keyword.get(opts, :idempotency_key)

      cmd =
        if idempotency_key do
          {:txn, Map.put(spec, :idempotency_key, idempotency_key)}
        else
          {:txn, spec}
        end

      case :ra.process_command(server_id(), cmd, timeout) do
        {:ok, {:ok, %Result{} = result}, _} ->
          {:ok, result}

        {:ok, {:ok, result}, _} when is_map(result) ->
          {:ok, struct(Result, result)}

        {:ok, {:error, reason}, _} ->
          {:error, reason}

        {:timeout, _} ->
          {:error, :timeout}

        {:error, :noproc} ->
          {:error, :cluster_not_ready}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp server_id, do: {@cluster_name, node()}
end
