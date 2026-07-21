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

  alias Concord.Engine
  alias Concord.Txn.Result
  alias Concord.Validation

  @timeout 5_000

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
    idempotency_key = Keyword.get(opts, :idempotency_key)

    with :ok <- Validation.validate_txn_spec(spec),
         :ok <- validate_idempotency_key(idempotency_key) do
      timeout = Keyword.get(opts, :timeout, @timeout)

      cmd =
        if is_binary(idempotency_key) do
          {:txn, Map.put(spec, :idempotency_key, idempotency_key)}
        else
          {:txn, spec}
        end

      engine_opts = Keyword.take(opts, [:engine])

      case Engine.command(cmd, Keyword.put(engine_opts, :timeout, timeout)) do
        {:ok, {:ok, %Result{} = result}} ->
          {:ok, result}

        {:ok, {:ok, result}} when is_map(result) ->
          {:ok, struct(Result, result)}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, :timeout} ->
          {:error, :timeout}

        {:error, :cluster_not_ready} ->
          {:error, :cluster_not_ready}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Resolves the result of a transaction submitted with an idempotency key.

  This is useful after a client timeout, when the transaction may have committed
  even though the caller did not receive its result.

  Returns `{:error, :not_found}` when the key has no retained transaction result.
  """
  @spec resolve(binary(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def resolve(idempotency_key, opts \\ []) do
    with :ok <- validate_required_idempotency_key(idempotency_key) do
      timeout = Keyword.get(opts, :timeout, @timeout)
      engine_opts = Keyword.take(opts, [:engine])

      case Engine.query(
             {:txn_result, idempotency_key},
             Keyword.put(engine_opts, :timeout, timeout)
           ) do
        {:ok, {:ok, %Result{} = result}} ->
          {:ok, result}

        {:ok, {:ok, result}} when is_map(result) ->
          {:ok, struct(Result, result)}

        {:ok, {:error, reason}} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_idempotency_key(nil), do: :ok

  defp validate_idempotency_key(key) do
    case Validation.validate_key(key) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_idempotency_key}
    end
  end

  defp validate_required_idempotency_key(nil), do: {:error, :invalid_idempotency_key}
  defp validate_required_idempotency_key(key), do: validate_idempotency_key(key)
end
