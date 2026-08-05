defmodule Nila.Storage.R2 do
  @behaviour Nila.Storage

  alias ExAws.S3

  @max_presign_ttl 300

  @impl true
  def put(key, data, opts) do
    bytes = IO.iodata_to_binary(data)
    byte_size = byte_size(bytes)
    content_type = Keyword.get(opts, :content_type, "application/octet-stream")

    bucket()
    |> S3.put_object(key, bytes,
      content_type: content_type,
      content_length: Integer.to_string(byte_size),
      meta: [{"byte-size", Integer.to_string(byte_size)}]
    )
    |> ExAws.request()
    |> case do
      {:ok, _response} ->
        {:ok, %{key: key, byte_size: byte_size, content_type: content_type}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get(key, _opts) do
    bucket()
    |> S3.get_object(key)
    |> ExAws.request()
    |> case do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(key, _opts) do
    bucket()
    |> S3.delete_object(key)
    |> ExAws.request()
    |> case do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def url(key, opts) do
    expires_in = Keyword.get(opts, :expires_in, @max_presign_ttl)

    if expires_in not in 1..@max_presign_ttl do
      raise ArgumentError, "presigned URL expiry must be between 1 and 300 seconds"
    end

    case S3.presigned_url(ExAws.Config.new(:s3), :get, bucket(), key, expires_in: expires_in) do
      {:ok, url} -> url
      {:error, reason} -> raise "could not presign storage URL: #{reason}"
    end
  end

  # Only the host is signed, so the browser is free to send its own
  # Content-Type. Signing that header instead would mean the upload fails
  # whenever the OS guesses a different type than the entry reported.
  @impl true
  def presign_put(key, opts) do
    expires_in = Keyword.get(opts, :expires_in, @max_presign_ttl)

    if expires_in not in 1..@max_presign_ttl do
      raise ArgumentError, "presigned URL expiry must be between 1 and 300 seconds"
    end

    S3.presigned_url(ExAws.Config.new(:s3), :put, bucket(), key, expires_in: expires_in)
  end

  defp bucket do
    Application.fetch_env!(:nila, __MODULE__)
    |> Keyword.fetch!(:bucket)
  end
end
