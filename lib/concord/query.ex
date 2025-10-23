defmodule Concord.Query do
  @moduledoc """
  Query language for Concord key-value store.

  Provides pattern matching, range queries, and filtering capabilities
  for efficient data retrieval.

  ## Features

  - **Pattern Matching**: Find keys by prefix, suffix, contains, or regex
  - **Range Queries**: Retrieve keys within a specific range
  - **Value Filtering**: Filter results by value predicates
  - **Limit & Offset**: Pagination support
  - **Sorted Results**: Automatic key sorting

  ## Examples

      # Find all user keys
      Concord.Query.keys(prefix: "user:")

      # Find keys in range
      Concord.Query.keys(range: {"user:100", "user:200"})

      # Find keys matching pattern
      Concord.Query.keys(pattern: ~r/user:\\d+/)

      # Get values with filtering
      Concord.Query.where(prefix: "product:", filter: fn {_k, v} -> v.price > 100 end)

      # Paginated results
      Concord.Query.keys(prefix: "order:", limit: 50, offset: 100)
  """

  require Logger

  @type key :: binary()
  @type value :: term()
  @type pattern :: Regex.t()
  @type range :: {key(), key()}
  @type filter_fn :: ({key(), value()} -> boolean())

  @type query_opts :: [
          prefix: binary(),
          suffix: binary(),
          contains: binary(),
          pattern: pattern(),
          range: range(),
          limit: pos_integer(),
          offset: non_neg_integer()
        ]

  @type where_opts :: [
          filter: filter_fn(),
          limit: pos_integer(),
          offset: non_neg_integer(),
          prefix: binary(),
          suffix: binary(),
          contains: binary(),
          pattern: pattern(),
          range: range()
        ]

  ## Public API

  @doc """
  Query keys matching the given criteria.

  ## Options

  - `:prefix` - Match keys starting with this string
  - `:suffix` - Match keys ending with this string
  - `:contains` - Match keys containing this string
  - `:pattern` - Match keys against a regex pattern
  - `:range` - Match keys in range `{start_key, end_key}` (inclusive)
  - `:limit` - Maximum number of results to return
  - `:offset` - Number of results to skip

  ## Examples

      # Prefix matching
      Concord.Query.keys(prefix: "user:")
      # => ["user:1", "user:2", "user:123"]

      # Range query
      Concord.Query.keys(range: {"user:100", "user:200"})
      # => ["user:100", "user:150", "user:200"]

      # Regex pattern
      Concord.Query.keys(pattern: ~r/user:\\d{3}/)
      # => ["user:100", "user:200", "user:999"]

      # Pagination
      Concord.Query.keys(prefix: "order:", limit: 50, offset: 100)
      # => 50 keys starting from the 101st key
  """
  @spec keys(query_opts()) :: {:ok, [key()]} | {:error, term()}
  def keys(opts \\ []) do
    with {:ok, all_keys} <- get_all_keys() do
      filtered_keys =
        all_keys
        |> apply_key_filters(opts)
        |> apply_pagination(opts)

      {:ok, filtered_keys}
    end
  end

  @doc """
  Query key-value pairs matching the given criteria.

  Similar to `keys/1` but returns both keys and values.

  ## Options

  Same as `keys/1`, plus:

  - `:filter` - A function `({key, value} -> boolean())` to filter results by value

  ## Examples

      # Get all user records
      Concord.Query.where(prefix: "user:")
      # => {:ok, [{"user:1", %{name: "Alice"}}, {"user:2", %{name: "Bob"}}]}

      # Filter by value
      Concord.Query.where(
        prefix: "product:",
        filter: fn {_k, v} -> v.price > 100 end
      )
      # => {:ok, [{"product:1", %{price: 150}}, {"product:2", %{price: 200}}]}

      # Range with filtering
      Concord.Query.where(
        range: {"order:2024-01-01", "order:2024-12-31"},
        filter: fn {_k, v} -> v.status == :completed end
      )
  """
  @spec where(where_opts()) :: {:ok, [{key(), value()}]} | {:error, term()}
  def where(opts \\ []) do
    filter_fn = Keyword.get(opts, :filter)

    with {:ok, keys} <- keys(opts),
         {:ok, pairs} <- get_key_values(keys) do
      filtered_pairs =
        if filter_fn do
          Enum.filter(pairs, filter_fn)
        else
          pairs
        end

      {:ok, filtered_pairs}
    end
  end

  @doc """
  Count keys matching the given criteria.

  ## Examples

      Concord.Query.count(prefix: "user:")
      # => {:ok, 1543}

      Concord.Query.count(range: {"order:2024-01-01", "order:2024-12-31"})
      # => {:ok, 8234}
  """
  @spec count(query_opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(opts \\ []) do
    case keys(opts) do
      {:ok, keys} -> {:ok, length(keys)}
      error -> error
    end
  end

  @doc """
  Delete all keys matching the given criteria.

  Returns the number of keys deleted.

  ## Examples

      # Delete all temporary keys
      Concord.Query.delete_where(prefix: "temp:")
      # => {:ok, 42}

      # Delete old orders
      Concord.Query.delete_where(range: {"order:2020-01-01", "order:2020-12-31"})
      # => {:ok, 1543}
  """
  @spec delete_where(query_opts()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_where(opts \\ []) do
    with {:ok, keys} <- keys(opts),
         {:ok, _results} <- Concord.delete_many(keys) do
      {:ok, length(keys)}
    end
  end

  ## Private Functions

  defp get_all_keys do
    case Concord.get_all() do
      {:ok, pairs} ->
        keys = Enum.map(pairs, fn {k, _v} -> k end) |> Enum.sort()
        {:ok, keys}

      error ->
        error
    end
  end

  defp get_key_values(keys) do
    case Concord.get_many(keys) do
      {:ok, results} ->
        # get_many returns [{key, {:ok, value}} | {key, {:error, :not_found}}]
        # Filter out errors and unwrap values
        pairs =
          results
          |> Enum.reject(fn {_k, result} -> match?({:error, _}, result) end)
          |> Enum.map(fn {k, {:ok, v}} -> {k, v} end)

        {:ok, pairs}

      error ->
        error
    end
  end

  defp apply_key_filters(keys, opts) do
    keys
    |> maybe_filter_prefix(opts)
    |> maybe_filter_suffix(opts)
    |> maybe_filter_contains(opts)
    |> maybe_filter_pattern(opts)
    |> maybe_filter_range(opts)
  end

  defp maybe_filter_prefix(keys, opts) do
    case Keyword.get(opts, :prefix) do
      nil -> keys
      prefix -> Enum.filter(keys, &String.starts_with?(&1, prefix))
    end
  end

  defp maybe_filter_suffix(keys, opts) do
    case Keyword.get(opts, :suffix) do
      nil -> keys
      suffix -> Enum.filter(keys, &String.ends_with?(&1, suffix))
    end
  end

  defp maybe_filter_contains(keys, opts) do
    case Keyword.get(opts, :contains) do
      nil -> keys
      substring -> Enum.filter(keys, &String.contains?(&1, substring))
    end
  end

  defp maybe_filter_pattern(keys, opts) do
    case Keyword.get(opts, :pattern) do
      nil -> keys
      %Regex{} = pattern -> Enum.filter(keys, &Regex.match?(pattern, &1))
    end
  end

  defp maybe_filter_range(keys, opts) do
    case Keyword.get(opts, :range) do
      nil ->
        keys

      {start_key, end_key} ->
        Enum.filter(keys, fn key ->
          key >= start_key && key <= end_key
        end)
    end
  end

  defp apply_pagination(keys, opts) do
    offset = Keyword.get(opts, :offset, 0)
    limit = Keyword.get(opts, :limit)

    keys
    |> Enum.drop(offset)
    |> maybe_take(limit)
  end

  defp maybe_take(enum, nil), do: enum
  defp maybe_take(enum, limit), do: Enum.take(enum, limit)
end
