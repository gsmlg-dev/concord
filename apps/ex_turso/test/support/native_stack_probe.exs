import ExUnit.Assertions

[fixtures, database] = System.argv()
{:ok, _} = Application.ensure_all_started(:ex_turso)

sql = File.read!(Path.join(fixtures, "fornacast_balanced_check.sql"))
witnesses = JSON.decode!(File.read!(Path.join(fixtures, "fornacast_witnesses.json")))
assert length(witnesses) == 10

{:ok, db} = Turso.Native.open(database)
{:ok, conn} = Turso.Native.connect(db)
assert {:ok, _} = Turso.Native.execute(conn, sql, [])

insert = "INSERT INTO cleanup VALUES (?, ?, ?, ?, ?, ?, ?)"

for mode <- [:execute, :query, :query_rows], witness <- witnesses do
  label = "#{mode}: #{witness["label"]}"
  IO.puts("starting #{label}")

  params = [
    JSON.encode!(witness["evidence"]),
    witness["kind"],
    witness["repository_id"],
    witness["repository_item_id"],
    witness["source_lock_version"],
    witness["effect_started_at"],
    witness["effect_finished_at"]
  ]

  statement = if mode == :execute, do: insert, else: insert <> " RETURNING kind"
  result = apply(Turso.Native, mode, [conn, statement, params])

  if witness["expect_accept"] do
    expected =
      case mode do
        :execute -> {:ok, 1}
        :query -> {:ok, [%{"kind" => witness["kind"]}]}
        :query_rows -> {:ok, {["kind"], [[witness["kind"]]]}}
      end

    assert result == expected, "#{label}: #{inspect(result)}"
  else
    assert {:error, {:constraint, message}} = result
    assert message =~ "github_import_cleanups_evidence_check"
  end

  IO.puts("verified #{label}")
end

expected_kinds =
  witnesses
  |> Enum.filter(& &1["expect_accept"])
  |> Enum.map(& &1["kind"])
  |> Enum.flat_map(&List.duplicate(&1, 3))
  |> Enum.sort()

assert {:ok, {["kind"], rows}} =
         Turso.Native.query_rows(conn, "SELECT kind FROM cleanup ORDER BY kind", [])

assert rows == Enum.map(expected_kinds, &[&1])
assert :ok = Turso.Native.close(conn)
assert :ok = Turso.Native.close_db(db)

{:ok, reopened_db} = Turso.Native.open(database)
{:ok, reopened_conn} = Turso.Native.connect(reopened_db)

assert {:ok, {["kind"], reopened_rows}} =
         Turso.Native.query_rows(reopened_conn, "SELECT kind FROM cleanup ORDER BY kind", [])

assert reopened_rows == rows

assert {:ok, [%{"count" => 9}]} =
         Turso.Native.query(reopened_conn, "SELECT count(*) AS count FROM cleanup", [])

assert :ok = Turso.Native.close(reopened_conn)
assert :ok = Turso.Native.close_db(reopened_db)

IO.puts("NATIVE STACK PROBE COMPLETE")
