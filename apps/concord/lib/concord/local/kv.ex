defmodule Concord.Local.KV do
  @moduledoc "Node-local `Concord.KV` API."

  alias Concord.{APIOptions, KV}

  def get(key, opts \\ []), do: KV.get(key, APIOptions.local(opts))
  def revision(opts \\ []), do: KV.revision(APIOptions.local(opts))
  def history(key, opts \\ []), do: KV.history(key, APIOptions.local(opts))
  def list(opts \\ []), do: KV.list(APIOptions.local(opts))
  def put(key, value, opts \\ []), do: KV.put(key, value, APIOptions.local(opts))
  def delete(key, opts \\ []), do: KV.delete(key, APIOptions.local(opts))
  def create(key, value, opts \\ []), do: KV.create(key, value, APIOptions.local(opts))
  def replace(key, value, opts \\ []), do: KV.replace(key, value, APIOptions.local(opts))

  def update_if(key, value, opts \\ []),
    do: KV.update_if(key, value, APIOptions.local(opts))

  def delete_if(key, opts \\ []), do: KV.delete_if(key, APIOptions.local(opts))
end
