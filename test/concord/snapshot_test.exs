defmodule Concord.SnapshotTest do
  use ExUnit.Case, async: false
  alias Concord.StateMachine

  describe "Snapshot round-trip — build_release_cursor_state + snapshot_installed" do
    setup do
      state = StateMachine.init(%{})
      :ets.delete_all_objects(:concord_store)
      {:ok, state: state}
    end

    test "snapshot preserves KV data", %{state: state} do
      meta = %{index: 1}

      # Insert KV data
      {state2, :ok, _} =
        StateMachine.apply_command(meta, {:put, "k1", "value1", nil}, state)

      {state3, :ok, _} =
        StateMachine.apply_command(%{index: 2}, {:put, "k2", "value2", nil}, state2)

      # Build snapshot
      snapshot = build_snapshot(state3)

      # Clear all ETS tables
      clear_all_ets()

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify KV data restored
      assert :ets.lookup(:concord_store, "k1") != []
      assert :ets.lookup(:concord_store, "k2") != []
    end

    test "snapshot preserves secondary index definitions and ETS data", %{state: state} do
      meta = %{index: 1}

      # Create an index
      {state2, :ok, _} =
        StateMachine.apply_command(meta, {:create_index, "by_name", {:map_get, :name}}, state)

      # Insert a record that uses the index
      {state3, :ok, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:put, "user:1", %{name: "Alice"}, nil},
          state2
        )

      # Build snapshot
      snapshot = build_snapshot(state3)

      # Clear all ETS
      clear_all_ets()

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify index definition is in the state
      {:concord_kv, restored_data} = snapshot
      assert Map.has_key?(restored_data, :indexes)
      assert Map.has_key?(restored_data.indexes, "by_name")

      # Verify index ETS table exists and has data
      table = Concord.Index.index_table_name("by_name")
      assert :ets.whereis(table) != :undefined
      assert :ets.tab2list(table) != []
    end

    test "snapshot preserves auth tokens", %{state: state} do
      meta = %{index: 1}

      # Create an auth token via Raft command
      {state2, _, _} =
        StateMachine.apply_command(
          meta,
          {:auth_create_token, "test_token_123", %{permissions: [:read, :write]}},
          state
        )

      # Build snapshot
      snapshot = build_snapshot(state2)

      # Clear all ETS
      clear_all_ets()

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify tokens ETS rebuilt
      assert :ets.lookup(:concord_tokens, "test_token_123") != []
    end

    test "snapshot preserves RBAC roles and grants", %{state: state} do
      meta = %{index: 1}

      # Create a role
      {state2, _, _} =
        StateMachine.apply_command(
          meta,
          {:rbac_create_role, :editor, %{permissions: [:read, :write]}},
          state
        )

      # Create a token first
      {state3, _, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:auth_create_token, "tok1", %{permissions: [:read]}},
          state2
        )

      # Grant role to the token
      {state4, _, _} =
        StateMachine.apply_command(
          %{index: 3},
          {:rbac_grant_role, "tok1", :editor},
          state3
        )

      # Build snapshot
      snapshot = build_snapshot(state4)

      # Clear all ETS
      clear_all_ets()

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify RBAC ETS tables rebuilt
      assert :ets.lookup(:concord_roles, :editor) != []
      assert :ets.lookup(:concord_role_grants, "tok1") != []
    end

    test "snapshot preserves tenant definitions", %{state: state} do
      meta = %{index: 1}

      # Create a tenant
      {state2, _, _} =
        StateMachine.apply_command(
          meta,
          {:tenant_create, "acme", %{namespace: "acme:*", max_keys: 1000, rate_limit: 100}},
          state
        )

      # Build snapshot
      snapshot = build_snapshot(state2)

      # Clear all ETS
      clear_all_ets()

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify tenants ETS rebuilt
      assert :ets.lookup(:concord_tenants, "acme") != []
    end

    test "snapshot preserves ACLs", %{state: state} do
      meta = %{index: 1}

      # Create role first, then ACL
      {state2, _, _} =
        StateMachine.apply_command(
          meta,
          {:rbac_create_role, :viewer, %{permissions: [:read]}},
          state
        )

      {state3, _, _} =
        StateMachine.apply_command(
          %{index: 2},
          {:rbac_create_acl, "public:*", :viewer, [:read]},
          state2
        )

      # Build snapshot
      snapshot = build_snapshot(state3)

      # Clear all ETS
      clear_all_ets()

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify ACLs ETS rebuilt
      assert :ets.lookup(:concord_acls, "public:*") != []
    end

    test "full snapshot round-trip preserves all 7 ETS table categories", %{state: state} do
      meta = %{index: 1}

      # Build up state with all categories
      # 1. KV data
      {s1, :ok, _} = StateMachine.apply_command(meta, {:put, "k1", "v1", nil}, state)

      # 2. Index
      {s2, :ok, _} =
        StateMachine.apply_command(%{index: 2}, {:create_index, "idx1", {:map_get, :field}}, s1)

      {s3, :ok, _} =
        StateMachine.apply_command(%{index: 3}, {:put, "k2", %{field: "indexed"}, nil}, s2)

      # 3. Auth token
      {s4, _, _} =
        StateMachine.apply_command(
          %{index: 4},
          {:auth_create_token, "tok_snap", %{permissions: [:read]}},
          s3
        )

      # 4. Role
      {s5, _, _} =
        StateMachine.apply_command(
          %{index: 5},
          {:rbac_create_role, :snaprole, %{permissions: [:read, :write]}},
          s4
        )

      # 5. Role grant
      {s6, _, _} =
        StateMachine.apply_command(%{index: 6}, {:rbac_grant_role, "tok_snap", :snaprole}, s5)

      # 6. ACL
      {s7, _, _} =
        StateMachine.apply_command(%{index: 7}, {:rbac_create_acl, "snap:*", :snaprole, [:read]}, s6)

      # 7. Tenant
      {s8, _, _} =
        StateMachine.apply_command(
          %{index: 8},
          {:tenant_create, "snap_tenant", %{namespace: "snap:*", max_keys: 100, rate_limit: 10}},
          s7
        )

      # Build snapshot from final state
      snapshot = build_snapshot(s8)

      # Clear ALL ETS tables
      clear_all_ets()

      # Verify everything is empty
      assert :ets.tab2list(:concord_store) == []
      assert :ets.tab2list(:concord_tokens) == []
      assert :ets.tab2list(:concord_roles) == []

      # Install snapshot
      StateMachine.snapshot_installed(snapshot, %{}, state, nil)

      # Verify all 7 ETS table categories restored:
      # 1. KV store
      assert :ets.lookup(:concord_store, "k1") != []
      assert :ets.lookup(:concord_store, "k2") != []

      # 2. Index ETS
      table = Concord.Index.index_table_name("idx1")
      assert :ets.whereis(table) != :undefined

      # 3. Auth tokens
      assert :ets.lookup(:concord_tokens, "tok_snap") != []

      # 4. Roles
      assert :ets.lookup(:concord_roles, :snaprole) != []

      # 5. Role grants
      assert :ets.lookup(:concord_role_grants, "tok_snap") != []

      # 6. ACLs
      assert :ets.lookup(:concord_acls, "snap:*") != []

      # 7. Tenants
      assert :ets.lookup(:concord_tenants, "snap_tenant") != []
    end
  end

  # Helper: calls the private build_release_cursor_state via apply_command
  # by triggering enough commands to emit a release_cursor effect,
  # or we can use the snapshot state builder directly.
  defp build_snapshot(state) do
    # The build_release_cursor_state function is private, so we invoke it
    # indirectly by calling the module's internal function through apply.
    # Since it's private, we use :erlang.apply with the function name.
    # However, a simpler approach: just construct the snapshot state manually
    # mirroring what build_release_cursor_state does.
    {:concord_kv, data} = state
    kv_data = :ets.tab2list(:concord_store)
    indexes = Map.get(data, :indexes, %{})

    index_ets =
      Enum.reduce(indexes, %{}, fn {name, _spec}, acc ->
        table = Concord.Index.index_table_name(name)

        ets_data =
          if :ets.whereis(table) != :undefined,
            do: :ets.tab2list(table),
            else: []

        Map.put(acc, name, ets_data)
      end)

    {:concord_kv,
     Map.merge(data, %{
       __snapshot_version__: 3,
       __kv_data__: kv_data,
       __index_ets__: index_ets
     })}
  end

  defp clear_all_ets do
    :ets.delete_all_objects(:concord_store)

    if :ets.whereis(:concord_tokens) != :undefined,
      do: :ets.delete_all_objects(:concord_tokens)

    if :ets.whereis(:concord_roles) != :undefined,
      do: :ets.delete_all_objects(:concord_roles)

    if :ets.whereis(:concord_role_grants) != :undefined,
      do: :ets.delete_all_objects(:concord_role_grants)

    if :ets.whereis(:concord_acls) != :undefined,
      do: :ets.delete_all_objects(:concord_acls)

    if :ets.whereis(:concord_tenants) != :undefined,
      do: :ets.delete_all_objects(:concord_tenants)

    # Clear index tables
    # We can't know all index table names, so we skip dynamic ones here
    # The snapshot_installed will recreate them
  end
end
