defmodule Nila.Storage.R2IntegrationTest do
  use ExUnit.Case, async: false

  alias Nila.Storage.R2

  @moduletag :r2_integration

  setup_all do
    endpoint = System.fetch_env!("R2_ENDPOINT")
    uri = URI.parse(endpoint)

    unless uri.scheme == "https" and is_binary(uri.host) and uri.path in [nil, ""] do
      raise "R2_ENDPOINT must be an HTTPS account endpoint without a path"
    end

    settings = [
      {:nila, Nila.Storage.R2, [bucket: System.fetch_env!("R2_BUCKET")]},
      {:ex_aws, :http_client, ExAws.Request.Req},
      {:ex_aws, :access_key_id, System.fetch_env!("R2_ACCESS_KEY_ID")},
      {:ex_aws, :secret_access_key, System.fetch_env!("R2_SECRET_ACCESS_KEY")},
      {:ex_aws, :region, "auto"},
      {:ex_aws, :s3, [scheme: "https://", host: uri.host, port: uri.port || 443]}
    ]

    previous =
      Map.new(settings, fn {app, key, _value} ->
        {{app, key}, Application.fetch_env(app, key)}
      end)
      |> Map.put({:ex_aws, :req_opts}, Application.fetch_env(:ex_aws, :req_opts))

    Enum.each(settings, fn {app, key, value} -> Application.put_env(app, key, value) end)
    Application.delete_env(:ex_aws, :req_opts)

    on_exit(fn ->
      Enum.each(previous, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  test "put, get, metadata, and delete against private R2" do
    key = "orgs/integration-smoke/#{Ecto.UUID.generate()}/original.txt"
    bytes = "nila-r2-smoke"

    assert {:ok, %{key: ^key, byte_size: 13, content_type: "text/plain"}} =
             R2.put(key, bytes, content_type: "text/plain")

    try do
      assert {:ok, ^bytes} = R2.get(key, [])

      assert {:ok, %{headers: headers}} =
               ExAws.S3.head_object(System.fetch_env!("R2_BUCKET"), key) |> ExAws.request()

      headers = Map.new(headers)
      assert headers["content-type"] == "text/plain"
      assert headers["content-length"] == "13"
      assert headers["x-amz-meta-byte-size"] == "13"
    after
      assert :ok = R2.delete(key, [])
    end

    assert {:error, _reason} = R2.get(key, [])
  end
end
