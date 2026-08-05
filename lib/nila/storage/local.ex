defmodule Nila.Storage.Local do
  @behaviour Nila.Storage

  @salt "storage local upload"
  @default_ttl 300

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

  # There is no bucket to presign against on disk, so dev and test stand in an
  # app endpoint that accepts the same browser PUT. The key travels in a signed
  # token rather than the query string: the browser must not get to name the
  # path it writes to.
  @impl true
  def presign_put(key, opts) do
    _ = path_for!(key)
    ttl = Keyword.get(opts, :expires_in, @default_ttl)
    token = Phoenix.Token.sign(secret(), @salt, key, max_age: ttl)
    {:ok, "/uploads/local?token=#{URI.encode_www_form(token)}"}
  end

  @doc """
  Reads back the storage key a `presign_put/2` token stands for.
  """
  def verify_upload_token(token, opts \\ []) do
    Phoenix.Token.verify(secret(), @salt, token,
      max_age: Keyword.get(opts, :max_age, @default_ttl)
    )
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

  defp secret do
    Application.fetch_env!(:nila, NilaWeb.Endpoint) |> Keyword.fetch!(:secret_key_base)
  end
end
