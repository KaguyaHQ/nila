defmodule Nila.Gst.Extraction.MistralDocumentAdapterTest do
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.MistralDocumentAdapter

  test "forces a direct pure-HTTP/1 connection with explicit timeouts" do
    request =
      Req.new(
        url: "https://api.mistral.ai/v1/ocr",
        adapter: MistralDocumentAdapter,
        connect_options: [timeout: 1_234],
        receive_timeout: 5_678
      )

    assert MistralDocumentAdapter.hackney_options(request) == [
             pool: false,
             protocols: [:http1],
             connect_timeout: 1_234,
             send_timeout: 5_678,
             recv_timeout: 5_678
           ]
  end

  test "two completed calls open two connections rather than reusing one" do
    {server, url} = start_server([:ok, :ok])

    assert {:ok, %{status: 200, body: "ok"}} =
             Req.get(url, adapter: MistralDocumentAdapter, retry: false)

    assert {:ok, %{status: 200, body: "ok"}} =
             Req.get(url, adapter: MistralDocumentAdapter, retry: false)

    assert_receive {:accepted, ^server, 1}
    assert_receive {:accepted, ^server, 2}
    refute_receive {:accepted, ^server, 3}
  end

  test "emits transport policy without exposing request content" do
    {server, url} = start_server([:ok])
    handler_id = {__MODULE__, self()}

    :telemetry.attach(
      handler_id,
      [:nila, :mistral, :document, :request, :stop],
      fn event, measurements, metadata, pid -> send(pid, {event, measurements, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{status: 200}} =
             Req.post(url,
               adapter: MistralDocumentAdapter,
               body: "sensitive document bytes",
               retry: false
             )

    assert_receive {:accepted, ^server, 1}

    assert_receive {[:nila, :mistral, :document, :request, :stop], measurements, metadata}
    assert is_integer(measurements.duration)
    assert metadata.provider == :mistral
    assert metadata.method == :post
    assert metadata.path == "/v1/ocr"
    assert metadata.protocol == :http1
    assert metadata.connection_policy == :unpooled
    assert metadata.status == 200
    refute Map.has_key?(metadata, :body)
  end

  test "a failed exchange cannot leave a socket for the next call" do
    {server, url} = start_server([:drop, :ok])

    assert {:error, %Req.TransportError{reason: :closed}} =
             Req.get(url, adapter: MistralDocumentAdapter, retry: false)

    assert {:ok, %{status: 200, body: "ok"}} =
             Req.get(url, adapter: MistralDocumentAdapter, retry: false)

    assert_receive {:accepted, ^server, 1}
    assert_receive {:accepted, ^server, 2}
  end

  test "rejects streaming and methods outside the document contract" do
    assert {:error, %ArgumentError{message: message}} =
             Req.put("http://localhost/",
               adapter: MistralDocumentAdapter,
               retry: false
             )

    assert message =~ "supports only GET, POST, and DELETE"

    assert {:error, %ArgumentError{message: message}} =
             Req.get("http://localhost/",
               adapter: MistralDocumentAdapter,
               into: :self,
               retry: false
             )

    assert message =~ "does not support streaming responses"
  end

  defp start_server(outcomes) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    test_pid = self()

    server =
      start_supervised!(
        {Task,
         fn ->
           outcomes
           |> Enum.with_index(1)
           |> Enum.each(fn {outcome, number} ->
             {:ok, socket} = :gen_tcp.accept(listener)
             send(test_pid, {:accepted, self(), number})
             read_request(socket)
             respond(socket, outcome)
             :gen_tcp.close(socket)
           end)

           :gen_tcp.close(listener)
         end}
      )

    {server, "http://127.0.0.1:#{port}/v1/ocr"}
  end

  defp respond(_socket, :drop), do: :ok

  defp respond(socket, :ok),
    do: :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")

  defp read_request(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_request, _method, _target, _version}} -> read_headers(socket)
      other -> raise "unexpected request: #{inspect(other)}"
    end
  end

  defp read_headers(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} -> :ok
      {:ok, {:http_header, _index, _name, _reserved, _value}} -> read_headers(socket)
      other -> raise "unexpected request header: #{inspect(other)}"
    end
  end
end
