[mode, directory] = System.argv()

if mode == "read" do
  Enum.each(1000..1//-1, &String.to_atom("concord_backup_checksum_field_#{&1}"))
end

fields = Map.new(1..1000, &{String.to_atom("concord_backup_checksum_field_#{&1}"), &1})

value = %{
  fields: fields,
  mixed_keys: %{1 => :integer, 1.0 => :float, "binary" => %{false => nil}},
  nested: [{:tuple, [true, 42.5, -123]}, ~D[2026-10-19]],
  improper: [:head | :tail],
  bits: <<5::3>>
}

:ok = Application.load(:concord)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = Application.ensure_all_started(:telemetry)
{:ok, _} = Concord.Engine.Local.start_link()

if mode == "write" do
  # Keep maps as terms so the checksum exercises map encoding, not an opaque
  # compressed value binary produced by the default large-value compression.
  :ok = Concord.Local.put("portable", value, compress: false)

  manifest =
    for compress <- [true, false] do
      {:ok, path} =
        Concord.Backup.create(
          path: Path.join(directory, to_string(compress)),
          compress: compress,
          engine: :local
        )

      {:ok, :valid} = Concord.Backup.verify(path)
      bytes = File.read!(path)
      %{metadata: metadata, data: data} = backup = :erlang.binary_to_term(bytes)
      :sha256_deterministic_etf_v1 = metadata.checksum_scheme

      legacy = %{
        backup
        | metadata:
            metadata
            |> Map.delete(:checksum_scheme)
            |> Map.put(:checksum, :crypto.hash(:sha256, :erlang.term_to_binary(data)))
      }

      legacy_path = path <> ".legacy"
      File.write!(legacy_path, :erlang.term_to_binary(legacy))
      {:ok, :valid} = Concord.Backup.verify(legacy_path)
      :ok = Concord.Backup.restore(legacy_path, engine: :local)
      {:ok, ^value} = Concord.Local.get("portable")

      {path, :crypto.hash(:sha256, bytes), legacy_path}
    end

  File.write!(Path.join(directory, "manifest.etf"), :erlang.term_to_binary(manifest))
else
  manifest = directory |> Path.join("manifest.etf") |> File.read!() |> :erlang.binary_to_term()

  for {path, checksum, legacy_path} <- manifest do
    ^checksum = :crypto.hash(:sha256, File.read!(path))
    {:ok, :valid} = Concord.Backup.verify(path)
    :ok = Concord.Local.put("sentinel", :keep_until_valid_restore)
    {:ok, :invalid} = Concord.Backup.verify(legacy_path)
    {:error, :invalid_backup} = Concord.Backup.restore(legacy_path, engine: :local)
    {:ok, :keep_until_valid_restore} = Concord.Local.get("sentinel")

    :ok = Concord.Backup.restore(path, engine: :local)
    {:ok, ^value} = Concord.Local.get("portable")
    {:error, :not_found} = Concord.Local.get("sentinel")
  end
end

IO.puts("backup checksum #{mode} passed")
