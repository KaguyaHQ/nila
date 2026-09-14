defmodule Nila.Gst.Extraction.NativeTablesTest do
  use ExUnit.Case, async: false

  alias Nila.Gst.Extraction.{NativeTables, SourcePages}
  alias Nila.PdfFixtures

  setup do
    original = Application.get_env(:nila, NativeTables)
    Application.delete_env(:nila, NativeTables)

    on_exit(fn ->
      if original,
        do: Application.put_env(:nila, NativeTables, original),
        else: Application.delete_env(:nila, NativeTables)
    end)
  end

  test "missing native tooling falls back to page images with a reason" do
    assert {:ok, source} = SourcePages.prepare(:sales, PdfFixtures.pdf(1), input: :native)

    assert {:vision, [{1, %{content_type: "image/jpeg"}}]} =
             SourcePages.invoice_inputs(source, [1])

    assert SourcePages.input_metadata(source)["native_fallbacks"]["document"] ==
             ":native_tables_not_configured"
  end

  test "an unavailable configured interpreter returns a failure" do
    Application.put_env(:nila, NativeTables,
      python: Path.join(System.tmp_dir!(), "missing-#{Ecto.UUID.generate()}")
    )

    assert {:error, :native_tables_unavailable} = NativeTables.extract("pdf", 1)
  end

  test "a scanned continuation keeps the complete invoice on images" do
    image = %{bytes: "image", content_type: "image/jpeg"}
    source = %{native_text: %{1 => "native invoice", 2 => ""}, full: %{1 => image, 2 => image}}
    assert {:text, [{1, "native invoice"}]} = SourcePages.invoice_inputs(source, [1])
    assert {:vision, [{1, ^image}, {2, ^image}]} = SourcePages.invoice_inputs(source, [1, 2])
  end
end
