defmodule Nila.Storage.Local do
  @behaviour Nila.Storage

  @impl true
  def put(key, data, opts) do
    path = path_for!(key)
    File.mkdir_p!(Path.dirname(path))
    bytes = IO.iodata_to_binary(data)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    case File.write(path, bytes) do
      :ok -> {:ok, %{key: key, byte_size: byte_size(bytes), content_type: content_type}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(key, _opts) do
    key
    |> path_for!()
    |> File.read()
  end

  @impl true
  def delete(key, _opts) do
    case File.rm(path_for!(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def url(key, _opts) do
    public_path = Keyword.fetch!(config(), :public_path)
    Path.join(public_path, normalize_key!(key))
  end

  defp path_for!(key) do
    root = Keyword.fetch!(config(), :root)
    Path.join(root, normalize_key!(key))
  end

  defp normalize_key!(key) when is_binary(key) do
    key = String.trim_leading(key, "/")
    parts = Path.split(key)

    if key == "" or Enum.any?(parts, &(&1 in ["..", ".", ""])) do
      raise ArgumentError, "invalid storage key"
    end

    Path.join(parts)
  end

  defp config, do: Application.fetch_env!(:nila, Nila.Storage)
end
