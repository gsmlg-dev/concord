defmodule Concord.Web.APIController do
  @moduledoc """
  Main API controller for Concord HTTP API endpoints.

  Handles all core CRUD operations, bulk operations,
  TTL management, and cluster status queries.
  """

  import Plug.Conn
  require Logger

  # Core CRUD Operations

  # PUT /api/v1/kv/:key
  def put(conn, key) do
    with {:ok, key} <- validate_key(key),
         {:ok, body} <- read_and_parse_body(conn),
         {:ok, params} <- validate_put_params(body) do
      case Concord.put(key, params.value, token_opts(conn)) do
        :ok ->
          send_success_response(conn, 200, %{"status" => "ok"})

        {:error, reason} ->
          handle_error(conn, reason, "Failed to store key")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # GET /api/v1/kv/:key
  def get(conn, key) do
    with {:ok, key} <- validate_key(key) do
      with_ttl = get_with_ttl_param(conn)

      result = if with_ttl do
        Concord.get_with_ttl(key, token_opts(conn))
      else
        Concord.get(key, token_opts(conn))
      end

      case result do
        {:ok, value} when not with_ttl ->
          send_success_response(conn, 200, %{
            "status" => "ok",
            "data" => %{"value" => value}
          })

        {:ok, {value, ttl}} when with_ttl ->
          send_success_response(conn, 200, %{
            "status" => "ok",
            "data" => %{
              "value" => value,
              "ttl" => ttl
            }
          })

        {:error, reason} ->
          handle_error(conn, reason, "Key not found")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # DELETE /api/v1/kv/:key
  def delete(conn, key) do
    with {:ok, key} <- validate_key(key) do
      case Concord.delete(key, token_opts(conn)) do
        :ok ->
          send_success_response(conn, 200, %{"status" => "ok"})

        {:error, reason} ->
          handle_error(conn, reason, "Failed to delete key")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # TTL Operations

  # POST /api/v1/kv/:key/touch
  def touch(conn, key) do
    with {:ok, key} <- validate_key(key),
         {:ok, body} <- read_and_parse_body(conn),
         {:ok, ttl} <- validate_ttl_param(body) do
      case Concord.touch(key, ttl, token_opts(conn)) do
        :ok ->
          send_success_response(conn, 200, %{"status" => "ok"})

        {:error, reason} ->
          handle_error(conn, reason, "Failed to extend TTL")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # GET /api/v1/kv/:key/ttl
  def ttl(conn, key) do
    with {:ok, key} <- validate_key(key) do
      case Concord.ttl(key, token_opts(conn)) do
        {:ok, ttl} ->
          send_success_response(conn, 200, %{
            "status" => "ok",
            "data" => %{"ttl" => ttl}
          })

        {:error, reason} ->
          handle_error(conn, reason, "Failed to get TTL")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # Bulk Operations

  # POST /api/v1/kv/bulk
  def put_bulk(conn) do
    with {:ok, body} <- read_and_parse_body(conn),
         {:ok, operations} <- validate_bulk_operations(body) do
      case Concord.put_many(operations, token_opts(conn)) do
        {:ok, results} ->
          send_success_response(conn, 200, %{
            "status" => "ok",
            "data" => results
          })

        {:error, reason} ->
          handle_error(conn, reason, "Bulk put operation failed")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # POST /api/v1/kv/bulk/get
  def get_bulk(conn) do
    with {:ok, body} <- read_and_parse_body(conn),
         {:ok, params} <- validate_bulk_get_params(body) do
      case Concord.get_many(params.keys, token_opts(conn)) do
        {:ok, results} ->
          # Transform results to API format
          api_results = transform_bulk_get_results(results, params.with_ttl)
          send_success_response(conn, 200, %{
            "status" => "ok",
            "data" => api_results
          })

        {:error, reason} ->
          handle_error(conn, reason, "Bulk get operation failed")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # POST /api/v1/kv/bulk/delete
  def delete_bulk(conn) do
    with {:ok, body} <- read_and_parse_body(conn),
         {:ok, keys} <- validate_bulk_keys(body) do
      case Concord.delete_many(keys, token_opts(conn)) do
        {:ok, results} ->
          send_success_response(conn, 200, %{
            "status" => "ok",
            "data" => results
          })

        {:error, reason} ->
          handle_error(conn, reason, "Bulk delete operation failed")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # POST /api/v1/kv/bulk/touch
  def touch_bulk(conn) do
    with {:ok, body} <- read_and_parse_body(conn),
         {:ok, operations} <- validate_bulk_touch_operations(body) do
      case Concord.touch_many(operations, token_opts(conn)) do
        {:ok, results} ->
          send_success_response(conn, 200, %{
            "status" => "ok",
            "data" => results
          })

        {:error, reason} ->
          handle_error(conn, reason, "Bulk touch operation failed")
      end
    else
      {:error, reason} ->
        handle_validation_error(conn, reason)
    end
  end

  # Administrative Operations

  # GET /api/v1/kv
  def get_all(conn) do
    with_ttl = get_with_ttl_param(conn)
    limit = get_limit_param(conn)

    result = if with_ttl do
      Concord.get_all_with_ttl(token_opts(conn))
    else
      Concord.get_all(token_opts(conn))
    end

    case result do
      {:ok, all_data} ->
        limited_data = if limit do
          Enum.take(all_data, limit)
        else
          all_data
        end

        send_success_response(conn, 200, %{
          "status" => "ok",
          "data" => limited_data
        })

      {:error, reason} ->
        handle_error(conn, reason, "Failed to get all keys")
    end
  end

  # GET /api/v1/status
  def status(conn) do
    case Concord.status() do
      {:ok, status} ->
        send_success_response(conn, 200, %{
          "status" => "ok",
          "data" => status
        })

      {:error, reason} ->
        handle_error(conn, reason, "Failed to get cluster status")
    end
  end

  # Fallback for unknown routes
  def not_found(conn) do
    send_error_response(conn, 404, %{
      "code" => "NOT_FOUND",
      "message" => "API endpoint not found"
    })
  end

  # Private helper functions

  defp read_and_parse_body(conn) do
    # Check if body params are already parsed (e.g., by Plug.Parsers or in tests)
    if conn.body_params != %Plug.Conn.Unfetched{} do
      {:ok, conn.body_params}
    else
      case read_body(conn) do
        {:ok, body, _conn} when is_binary(body) ->
          case Jason.decode(body) do
            {:ok, data} -> {:ok, data}
            {:error, _} -> {:error, :invalid_json}
          end

        {:ok, _body, _conn} ->
          {:error, :invalid_body}

        {:more, _data, _conn} ->
          {:error, :body_too_large}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_key(key) when is_binary(key) and byte_size(key) > 0 and byte_size(key) <= 1024 do
    {:ok, key}
  end
  defp validate_key(_), do: {:error, :invalid_key}

  defp validate_put_params(%{"value" => value} = params) do
    ttl = Map.get(params, "ttl")
    result = if ttl do
      case validate_ttl(ttl) do
        :ok -> {:ok, %{value: value, ttl: ttl}}
        error -> error
      end
    else
      {:ok, %{value: value}}
    end

    result
  end
  defp validate_put_params(_), do: {:error, :invalid_put_params}

  defp validate_ttl_param(%{"ttl" => ttl}) when is_integer(ttl) and ttl > 0 do
    {:ok, ttl}
  end
  defp validate_ttl_param(_), do: {:error, :invalid_ttl}

  defp validate_ttl(ttl) when is_integer(ttl) and ttl > 0, do: :ok
  defp validate_ttl(_), do: {:error, :invalid_ttl}

  defp validate_bulk_operations(%{"operations" => operations}) when is_list(operations) do
    case validate_bulk_operations_list(operations) do
      :ok -> {:ok, operations}
      error -> error
    end
  end
  defp validate_bulk_operations(_), do: {:error, :invalid_bulk_operations}

  defp validate_bulk_operations_list([]), do: {:error, :empty_operations}
  defp validate_bulk_operations_list(operations) do
    if length(operations) > 500 do
      {:error, :batch_too_large}
    else
      case Enum.find_value(operations, :ok, fn op -> validate_bulk_operation(op) end) do
        :ok -> :ok
        error -> error
      end
    end
  end

  defp validate_bulk_operation(%{"key" => key} = op) when is_binary(key) do
    with {:ok, _} <- validate_key(key) do
      case Map.get(op, "ttl") do
        nil -> :ok
        ttl -> validate_ttl(ttl)
      end
    end
  end
  defp validate_bulk_operation(_), do: {:error, :invalid_operation}

  defp validate_bulk_get_params(%{"keys" => keys} = params) when is_list(keys) do
    with :ok <- validate_bulk_keys_list(keys) do
      with_ttl = Map.get(params, "with_ttl", false)
      {:ok, %{keys: keys, with_ttl: with_ttl}}
    end
  end
  defp validate_bulk_get_params(_), do: {:error, :invalid_bulk_get_params}

  defp validate_bulk_keys(%{"keys" => keys}) when is_list(keys) do
    case validate_bulk_keys_list(keys) do
      :ok -> {:ok, keys}
      error -> error
    end
  end
  defp validate_bulk_keys(_), do: {:error, :invalid_bulk_keys}

  defp validate_bulk_keys_list([]), do: {:error, :empty_keys}
  defp validate_bulk_keys_list(keys) do
    if length(keys) > 500 do
      {:error, :batch_too_large}
    else
      case Enum.find_value(keys, :ok, fn key -> validate_key(key) end) do
        :ok -> :ok
        error -> error
      end
    end
  end

  defp validate_bulk_touch_operations(%{"operations" => operations}) when is_list(operations) do
    case validate_bulk_touch_operations_list(operations) do
      :ok -> {:ok, operations}
      error -> error
    end
  end
  defp validate_bulk_touch_operations(_), do: {:error, :invalid_bulk_touch_operations}

  defp validate_bulk_touch_operations_list([]), do: {:error, :empty_operations}
  defp validate_bulk_touch_operations_list(operations) do
    if length(operations) > 500 do
      {:error, :batch_too_large}
    else
      case Enum.find_value(operations, :ok, fn op -> validate_touch_operation(op) end) do
        :ok -> :ok
        error -> error
      end
    end
  end

  defp validate_touch_operation(%{"key" => key, "ttl" => ttl}) when is_binary(key) and is_integer(ttl) and ttl > 0 do
    case validate_key(key) do
      {:ok, _} -> :ok
      error -> error
    end
  end
  defp validate_touch_operation(_), do: {:error, :invalid_touch_operation}

  defp transform_bulk_get_results(results, with_ttl) do
    Enum.map(results, fn {key, result} ->
      case result do
        {:ok, value} when not with_ttl ->
          {key, %{"status" => "ok", "value" => value}}

        {:ok, {value, ttl}} when with_ttl ->
          {key, %{"status" => "ok", "value" => value, "ttl" => ttl}}

        {:error, reason} ->
          {key, %{"status" => "error", "error" => Atom.to_string(reason)}}
      end
    end)
    |> Map.new()
  end

  defp get_with_ttl_param(conn) do
    case get_query_param(conn, "with_ttl") do
      "true" -> true
      "1" -> true
      _ -> false
    end
  end

  defp get_limit_param(conn) do
    case get_query_param(conn, "limit") do
      limit when is_binary(limit) ->
        case Integer.parse(limit) do
          {n, ""} when n > 0 -> n
          _ -> nil
        end
      _ -> nil
    end
  end

  defp get_query_param(conn, key) do
    case conn.query_params do
      %Plug.Conn.Unfetched{} -> fetch_query_params(conn).query_params[key]
      params -> params[key]
    end
  end

  defp token_opts(conn) do
    case conn.assigns[:auth_token] do
      nil -> []
      token -> [token: token]
    end
  end

  defp send_success_response(conn, status, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(data))
  end

  defp send_error_response(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{
      "status" => "error",
      "error" => error
    }))
  end

  defp handle_error(conn, reason, message) do
    Logger.debug("#{message}: #{inspect(reason)}")

    error_code = case reason do
      :not_found -> "NOT_FOUND"
      :invalid_key -> "INVALID_KEY"
      :timeout -> "TIMEOUT"
      :cluster_not_ready -> "CLUSTER_UNAVAILABLE"
      :batch_too_large -> "BATCH_TOO_LARGE"
      :unauthorized -> "UNAUTHORIZED"
      _ -> "OPERATION_FAILED"
    end

    send_error_response(conn, case reason do
      :not_found -> 404
      :timeout -> 408
      :unauthorized -> 401
      :cluster_not_ready -> 503
      _ -> 400
    end, %{
      "code" => error_code,
      "message" => message
    })
  end

  defp handle_validation_error(conn, reason) do
    error_map = case reason do
      :invalid_key -> %{"code" => "INVALID_KEY", "message" => "Key cannot be empty and must be <= 1024 bytes"}
      :invalid_json -> %{"code" => "INVALID_REQUEST", "message" => "Malformed JSON in request body"}
      :invalid_put_params -> %{"code" => "INVALID_REQUEST", "message" => "Missing or invalid 'value' field"}
      :invalid_ttl -> %{"code" => "INVALID_REQUEST", "message" => "TTL must be a positive integer"}
      :invalid_bulk_operations -> %{"code" => "INVALID_REQUEST", "message" => "Missing or invalid 'operations' field"}
      :invalid_bulk_get_params -> %{"code" => "INVALID_REQUEST", "message" => "Missing or invalid 'keys' field"}
      :invalid_bulk_keys -> %{"code" => "INVALID_REQUEST", "message" => "Missing or invalid 'keys' field"}
      :invalid_bulk_touch_operations -> %{"code" => "INVALID_REQUEST", "message" => "Missing or invalid 'operations' field"}
      :empty_operations -> %{"code" => "INVALID_REQUEST", "message" => "Operations list cannot be empty"}
      :empty_keys -> %{"code" => "INVALID_REQUEST", "message" => "Keys list cannot be empty"}
      :batch_too_large -> %{"code" => "BATCH_TOO_LARGE", "message" => "Batch size exceeds 500 operations limit"}
      :invalid_operation -> %{"code" => "INVALID_REQUEST", "message" => "Invalid operation format"}
      :invalid_touch_operation -> %{"code" => "INVALID_REQUEST", "message" => "Invalid touch operation format"}
      _ -> %{"code" => "VALIDATION_ERROR", "message" => "Request validation failed"}
    end

    status = case reason do
      :batch_too_large -> 413
      _ -> 400
    end

    send_error_response(conn, status, error_map)
  end
end