defmodule TursoTest do
  use ExUnit.Case, async: true

  alias Turso.Result

  setup do
    # Each test gets its own in-memory database with a single connection so the
    # data stays on one handle.
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({Turso, database: ":memory:", name: name, pool_size: 1})
    {:ok, _} = Turso.execute(name, "CREATE TABLE users (id INTEGER, name TEXT, score REAL)")
    %{db: name}
  end

  test "execute reports affected rows", %{db: db} do
    assert {:ok, %Result{num_rows: 1, rows: nil}} =
             Turso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 9.5])
  end

  test "query returns rows as maps keyed by column name", %{db: db} do
    {:ok, _} = Turso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 9.5])

    assert {:ok, %Result{num_rows: 1, rows: [%{"id" => 1, "name" => "Alice", "score" => 9.5}]}} =
             Turso.query(db, "SELECT id, name, score FROM users WHERE id = ?", [1])
  end

  test "parameters bind across types including nil", %{db: db} do
    {:ok, _} = Turso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [2, "Bob", nil])

    assert {:ok, %Result{rows: [%{"name" => "Bob", "score" => nil}]}} =
             Turso.query(db, "SELECT name, score FROM users WHERE id = ?", [2])
  end

  test "empty result set", %{db: db} do
    assert {:ok, %Result{num_rows: 0, rows: []}} =
             Turso.query(db, "SELECT * FROM users", [])
  end

  test "errors surface as {:error, exception}", %{db: db} do
    assert {:error, %Turso.Error{message: message}} =
             Turso.query(db, "SELECT * FROM nonexistent", [])

    assert is_binary(message)
  end

  test "transaction commits", %{db: db} do
    {:ok, _} = Turso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 1.0])

    assert {:ok, :done} =
             DBConnection.transaction(db, fn conn ->
               {:ok, _} =
                 Turso.execute(conn, "UPDATE users SET score = ? WHERE id = ?", [10.0, 1])

               :done
             end)

    assert {:ok, %Result{rows: [%{"score" => 10.0}]}} =
             Turso.query(db, "SELECT score FROM users WHERE id = ?", [1])
  end

  test "transaction rolls back on error", %{db: db} do
    {:ok, _} = Turso.execute(db, "INSERT INTO users VALUES (?, ?, ?)", [1, "Alice", 1.0])

    assert {:error, :boom} =
             DBConnection.transaction(db, fn conn ->
               {:ok, _} =
                 Turso.execute(conn, "UPDATE users SET score = ? WHERE id = ?", [99.0, 1])

               DBConnection.rollback(conn, :boom)
             end)

    assert {:ok, %Result{rows: [%{"score" => 1.0}]}} =
             Turso.query(db, "SELECT score FROM users WHERE id = ?", [1])
  end

  test "blob parameters bind and return as binary", %{db: db} do
    {:ok, _} = Turso.execute(db, "CREATE TABLE blobs (id INTEGER, data BLOB)")
    blob = <<0, 1, 2, 255>>
    {:ok, _} = Turso.execute(db, "INSERT INTO blobs VALUES (?, ?)", [1, blob])

    assert {:ok, %Result{rows: [%{"data" => ^blob}]}} =
             Turso.query(db, "SELECT data FROM blobs WHERE id = ?", [1])
  end

  test "ping/1 callback runs a real query against the connection" do
    {:ok, state} = Turso.Connection.connect(database: ":memory:")
    assert {:ok, ^state} = Turso.Connection.ping(state)
  end

  @tag :tmp_dir
  test "disconnect/2 releases native connection and database handles", %{tmp_dir: tmp_dir} do
    db_path = Path.join(tmp_dir, "disconnect_releases_handles.db")

    assert {:ok, state} = Turso.Connection.connect(database: db_path)
    assert {:ok, _} = Turso.Native.execute(state.conn, "CREATE TABLE released (id INTEGER)", [])

    assert :ok = Turso.Connection.disconnect(:normal, state)

    assert {:error, {:error, "connection is closed"}} =
             Turso.Native.query_rows(state.conn, "SELECT 1", [])

    assert {:error, {:error, "database is closed"}} = Turso.Native.connect(state.db)

    assert {:ok, reopened} = Turso.Connection.connect(database: db_path)

    assert {:ok, {["count"], [[1]]}} =
             Turso.Native.query_rows(
               reopened.conn,
               "SELECT COUNT(*) AS count FROM sqlite_schema WHERE name = 'released'",
               []
             )

    assert :ok = Turso.Connection.disconnect(:normal, reopened)
  end

  test "status changes between idle and transaction", %{db: db} do
    assert :idle = DBConnection.status(db)

    {:ok, _} =
      DBConnection.transaction(db, fn conn ->
        assert :transaction = DBConnection.status(conn)
      end)
  end

  test "cursors callbacks return unsupported error" do
    state = %Turso.Connection{}
    query = %Turso.Query{}

    assert {:error, %Turso.Error{message: "cursors are not supported"}, ^state} =
             Turso.Connection.handle_declare(query, [], [], state)

    assert {:error, %Turso.Error{message: "cursors are not supported"}, ^state} =
             Turso.Connection.handle_fetch(query, :cursor, [], state)

    assert {:error, %Turso.Error{message: "cursors are not supported"}, ^state} =
             Turso.Connection.handle_deallocate(query, :cursor, [], state)
  end

  test "connect/1 callback raises KeyError if :database is missing" do
    assert_raise KeyError, fn ->
      Turso.Connection.connect([])
    end
  end

  test "connect/1 callback returns error on invalid database path" do
    assert {:error, %Turso.Error{message: message}} = Turso.Connection.connect(database: "")
    assert is_binary(message)
  end

  @tag :tmp_dir
  test "handles concurrent queries with a pool", %{tmp_dir: tmp_dir} do
    db_path = Path.join(tmp_dir, "concurrent_test.db")
    pool_name = :"db_pool_#{System.unique_integer([:positive])}"

    spec = %{
      id: pool_name,
      start: {Turso, :start_link, [[database: db_path, name: pool_name, pool_size: 5]]}
    }

    start_supervised!(spec)

    {:ok, _} = Turso.execute(pool_name, "CREATE TABLE items (val INTEGER)")

    # Populate data
    for i <- 1..50 do
      {:ok, _} = Turso.execute(pool_name, "INSERT INTO items VALUES (?)", [i])
    end

    # Query concurrently
    results =
      1..50
      |> Task.async_stream(fn i ->
        Turso.query(pool_name, "SELECT val FROM items WHERE val = ?", [i])
      end)
      |> Enum.to_list()

    # Every task must have completed and every query must have succeeded.
    assert length(results) == 50

    for {:ok, result} <- results do
      assert {:ok, %Result{rows: [%{"val" => val}]}} = result
      assert val in 1..50
    end
  end

  test "vector search functions compile and execute successfully", %{db: db} do
    # Create table with vector column (represented as F32_BLOB or general BLOB)
    {:ok, _} = Turso.execute(db, "CREATE TABLE items_vector (id INTEGER, embedding BLOB)")

    # Insert float vector data using SQLite vector representation
    {:ok, _} =
      Turso.execute(db, "INSERT INTO items_vector VALUES (?, vector32('[1.0, 2.0, 3.0]'))", [1])

    {:ok, _} =
      Turso.execute(db, "INSERT INTO items_vector VALUES (?, vector32('[4.0, 5.0, 6.0]'))", [2])

    # Query with vector distance calculation (using cosine similarity/distance)
    assert {:ok, %Result{rows: [%{"id" => 1, "distance" => distance}]}} =
             Turso.query(
               db,
               "SELECT id, vector_distance_cos(embedding, vector32('[1.0, 2.0, 3.0]')) as distance FROM items_vector ORDER BY distance LIMIT 1"
             )

    assert abs(distance) < 1.0e-5
  end

  test "full-text search index supports MATCH queries", %{db: db} do
    {:ok, _} = Turso.execute(db, "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)")
    {:ok, _} = Turso.execute(db, "CREATE INDEX docs_fts ON docs USING fts (content)")
    {:ok, _} = Turso.execute(db, "INSERT INTO docs VALUES (?, ?)", [1, "alpha beta"])
    {:ok, _} = Turso.execute(db, "INSERT INTO docs VALUES (?, ?)", [2, "gamma delta"])

    assert {:ok, %Result{rows: [%{"id" => 1}]}} =
             Turso.query(
               db,
               "SELECT id FROM docs WHERE (content) MATCH ? ORDER BY id",
               ["alpha"]
             )
  end

  test "sync/2 returns error if database is not configured for sync", %{db: db} do
    assert {:error, %Turso.Error{message: "database is not configured for cloud sync"}} =
             Turso.sync(db)
  end

  test "sync/2 returns error if called inside a transaction", %{db: db} do
    assert {:error, %Turso.Error{message: "cannot sync database inside a transaction"}} =
             DBConnection.transaction(db, fn conn ->
               case Turso.sync(conn) do
                 {:error, err} -> DBConnection.rollback(conn, err)
                 _ -> :ok
               end
             end)
  end

  test "connect/1 returns error if only one of remote_url or auth_token is provided" do
    assert {:error,
            %Turso.Error{
              message: "both :remote_url and :auth_token must be provided for a synced database"
            }} =
             Turso.Connection.connect(
               database: ":memory:",
               remote_url: "libsql://some-url.turso.io"
             )

    assert {:error,
            %Turso.Error{
              message: "both :remote_url and :auth_token must be provided for a synced database"
            }} =
             Turso.Connection.connect(database: ":memory:", auth_token: "some-token")
  end

  test "connect/1 resolves a zero-arity function as auth_token" do
    # The function resolves to nil, so validation must treat the token as absent.
    assert {:error,
            %Turso.Error{
              message: "both :remote_url and :auth_token must be provided for a synced database"
            }} =
             Turso.Connection.connect(
               database: ":memory:",
               remote_url: "libsql://some-url.turso.io",
               auth_token: fn -> nil end
             )
  end

  test "boolean parameters bind as integers 1 and 0", %{db: db} do
    assert {:ok, %Result{rows: [%{"t" => 1, "f" => 0}]}} =
             Turso.query(db, "SELECT ? AS t, ? AS f", [true, false])
  end

  test "unsupported parameter types return :invalid_param instead of binding NULL", %{db: db} do
    for param <- [:some_atom, [1, 2], %{a: 1}, 36_893_488_147_419_103_232] do
      assert {:error, %Turso.Error{code: :invalid_param, message: message}} =
               Turso.query(db, "SELECT ?", [param])

      assert message =~ "index 0"
    end
  end

  test "constraint violations carry the :constraint error code", %{db: db} do
    {:ok, _} = Turso.execute(db, "CREATE TABLE uniq (id INTEGER PRIMARY KEY)")
    {:ok, _} = Turso.execute(db, "INSERT INTO uniq VALUES (?)", [1])

    assert {:error, %Turso.Error{code: :constraint}} =
             Turso.execute(db, "INSERT INTO uniq VALUES (?)", [1])
  end
end
