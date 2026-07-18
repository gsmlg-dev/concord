defmodule ViewstampedReplication.Storage do
  @moduledoc """
  Durable-state adapter contract used by a replica runtime.

  Adapter state is owned by the replica process. Mutating callbacks return the
  updated adapter state so storage implementations do not need a process of
  their own.
  """

  alias ViewstampedReplication.{Log, LogEntry}

  @type recovered_state :: %{
          required(:configuration_hash) => binary(),
          required(:replica_id) => term(),
          required(:hard_state) => map(),
          required(:log) => Log.t(),
          required(:commit_number) => non_neg_integer(),
          required(:applied_number) => non_neg_integer(),
          required(:snapshot) => term() | nil,
          required(:client_table) => map()
        }

  @callback open(keyword()) :: {:ok, term()} | {:error, term()}
  @callback recover(term()) :: {:ok, recovered_state(), term()} | {:error, term()}
  @callback persist_hard_state(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback append(term(), LogEntry.t() | [LogEntry.t()]) :: {:ok, term()} | {:error, term()}
  @callback truncate_suffix(term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  @callback set_commit_number(term(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  @callback set_applied(term(), non_neg_integer(), map()) ::
              {:ok, term()} | {:error, term()}
  @callback write_snapshot(term(), term()) :: {:ok, term()} | {:error, term()}
  @callback install_snapshot(term(), term()) :: {:ok, term()} | {:error, term()}
  @callback install_state(term(), map()) :: {:ok, term()} | {:error, term()}
  @callback close(term()) :: :ok | {:error, term()}
end
