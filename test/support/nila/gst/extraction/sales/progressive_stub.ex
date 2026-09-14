defmodule Nila.Gst.Extraction.Sales.ProgressiveStub do
  @behaviour Nila.Gst.Extraction.Sales
  def extract(bytes, opts) do
    owner = :erlang.binary_to_term(bytes, [:safe])
    {:ok, result} = Nila.Gst.Extraction.Sales.Stub.extract("", [])
    [first, second | _] = result.pages
    second = put_in(second, ["data", "printed_grand_total"], 15_000)

    segments =
      Enum.map([first, second], fn artifact ->
        %{
          "pages" => artifact["source_pages"],
          "kind" => "invoice",
          "invoice_no" => nil,
          "reason" => nil
        }
      end)

    opts[:on_segments].(segments)
    opts[:on_progress].({:progress, %{stage: :reading, done: 0, total: 2}})

    unless Map.has_key?(opts[:completed_artifacts], "2"),
      do: opts[:on_invoice].(second, 2, result.images)

    opts[:on_progress].({:progress, %{stage: :reading, done: 1, total: 2}})
    send(owner, {:partial_saved, self()})

    receive do
      :finish ->
        opts[:on_invoice].(first, 1, result.images)
        opts[:on_progress].({:progress, %{stage: :reading, done: 2, total: 2}})
        {:ok, %{result | pages: [first, second]}}

      :fail ->
        opts[:on_invoice_failed].(1)
        {:error, :invalid_json}
    after
      15_000 -> raise "Test did not release extraction"
    end
  end
end
