defmodule Nila.TestFailingStorageAdapter do
  @behaviour Nila.Storage

  @impl true
  def put(_key, _data, _opts), do: {:error, :storage_down}

  @impl true
  def get(_key, _opts), do: {:error, :storage_down}

  @impl true
  def delete(_key, _opts), do: {:error, :storage_down}

  @impl true
  def url(_key, _opts), do: raise("storage down")

  @impl true
  def presign_put(_key, _opts), do: {:error, :storage_down}
end
