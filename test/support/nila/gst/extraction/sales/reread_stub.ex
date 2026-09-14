defmodule Nila.Gst.Extraction.Sales.RereadStub do
  def provider, do: "test"
  def model, do: "reread"

  def extract(bytes, opts) do
    send(self(), {:reread_options, opts})
    callback = Process.get(:reread_callback, fn -> :ok end)

    case callback.() do
      :ok -> Nila.Gst.Extraction.Sales.Stub.extract(bytes, opts)
      result -> result
    end
  end
end
