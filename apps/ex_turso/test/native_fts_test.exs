defmodule Turso.NativeFTSTest do
  use ExUnit.Case, async: true

  alias Turso.Native

  @tag :tmp_dir
  test "FTS indexes preserve committed updates and rollback across reopen", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "fts.db")

    with_connection(path, fn conn ->
      assert {:ok, _} =
               Native.execute(
                 conn,
                 "CREATE TABLE docs (id INTEGER PRIMARY KEY, content TEXT)",
                 []
               )

      assert {:ok, _} =
               Native.execute(conn, "CREATE INDEX docs_fts ON docs USING fts (content)", [])

      assert {:ok, 1} = Native.execute(conn, "INSERT INTO docs VALUES (?, ?)", [1, "alpha beta"])
      assert {:ok, 1} = Native.execute(conn, "INSERT INTO docs VALUES (?, ?)", [2, "gamma delta"])
      assert_matches(conn, [1])
    end)

    with_connection(path, fn conn ->
      assert_matches(conn, [1])
      assert {:ok, _} = Native.execute(conn, "BEGIN", [])

      assert {:ok, 1} =
               Native.execute(conn, "INSERT INTO docs VALUES (?, ?)", [3, "alpha rollback"])

      assert {:ok, _} = Native.execute(conn, "ROLLBACK", [])
      assert_matches(conn, [1])

      assert {:ok, _} = Native.execute(conn, "BEGIN", [])

      assert {:ok, 1} =
               Native.execute(conn, "UPDATE docs SET content = ? WHERE id = ?", [
                 "alpha update",
                 2
               ])

      assert {:ok, 1} = Native.execute(conn, "DELETE FROM docs WHERE id = ?", [1])
      assert {:ok, _} = Native.execute(conn, "COMMIT", [])
      assert_matches(conn, [2])
    end)

    with_connection(path, &assert_matches(&1, [2]))
  end

  defp assert_matches(conn, ids) do
    assert {:ok, {["id"], rows}} =
             Native.query_rows(conn, "SELECT id FROM docs WHERE (content) MATCH ? ORDER BY id", [
               "alpha"
             ])

    assert rows == Enum.map(ids, &[&1])
  end

  defp with_connection(path, fun) do
    assert {:ok, db} = Native.open(path)

    try do
      assert {:ok, conn} = Native.connect(db)

      try do
        fun.(conn)
      after
        assert :ok = Native.close(conn)
      end
    after
      assert :ok = Native.close_db(db)
    end
  end
end
