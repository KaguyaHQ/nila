defmodule Nila.Business.PdfTest do
  use ExUnit.Case, async: false

  alias Nila.Business.Pdf

  setup do
    previous = Application.get_env(:nila, Pdf)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nila, Pdf, previous),
        else: Application.delete_env(:nila, Pdf)
    end)

    :ok
  end

  test "reports a missing renderer without writing a document" do
    Application.put_env(:nila, Pdf, bin: "nila-missing-typst-binary")
    assert {:error, :pdf_renderer_unavailable} = Pdf.render(snapshot())
  end

  describe "actual PDF rendering" do
    @describetag skip: is_nil(System.find_executable(System.get_env("TYPST_BIN") || "typst"))

    test "draft preview is clearly marked and does not claim to be issued" do
      data = Map.merge(snapshot(), %{"number" => "DRAFT", "draft" => true})
      assert {:ok, bytes} = Pdf.render(data)
      text = pdf_text(bytes)
      assert text =~ "DRAFT"
      refute text =~ "Issued"
    end

    test "quotation reuses the template with quotation identity and validity" do
      data =
        Map.merge(snapshot(), %{
          "document_type" => "quotation",
          "number" => "QT/2627/0001",
          "valid_until" => "2026-10-15"
        })

      assert {:ok, bytes} = Pdf.render(data)
      text = pdf_text(bytes)
      assert text =~ "QUOTATION"
      assert text =~ "QT/2627/0001"
      assert text =~ "Valid until"
      assert text =~ "2026-10-15"
      assert text =~ "not a tax invoice"
      refute text =~ "TAX INVOICE"
      refute text =~ "Issued"
    end

    test "renders optional reference, delivery address and amount words" do
      data =
        Map.merge(snapshot(), %{
          "purchase_order_number" => "WO-4821",
          "purchase_order_date" => "2026-09-01",
          "delivery_address" => "Military Hospital Secunderabad",
          "total_in_words" => "Rupees Twenty Three Thousand Three Hundred Sixty Four only"
        })

      assert {:ok, bytes} = Pdf.render(data)
      text = pdf_text(bytes)
      assert text =~ "WO-4821"
      assert text =~ "2026-09-01"
      assert text =~ "Military Hospital Secunderabad"
      assert text =~ "Twenty Three Thousand Three Hundred Sixty Four"
    end

    test "renders paise exactly and treats markup as customer text" do
      data = snapshot()
      data = put_in(data, ["customer", "name"], "Renée & Co #read(\"secret\")")
      assert {:ok, <<"%PDF-", _::binary>> = bytes} = Pdf.render(data)

      text = pdf_text(bytes)
      assert text =~ "Renée & Co #read(\"secret\")"
      assert text =~ ~r/₹\s*1,234\.57/
      assert text =~ ~r/₹\s*1,456\.79/
      assert text =~ "Tamil Nadu (33)"
      assert text =~ "CGST"
      assert text =~ "SGST"
    end

    test "prints the copied service unit beside quantity" do
      data = snapshot()
      [line] = data["lines"]
      data = Map.put(data, "lines", [Map.put(line, "unit", "hours")])
      assert {:ok, bytes} = Pdf.render(data)
      assert pdf_text(bytes) =~ "hours"
    end

    test "retains all sixty long service rows across pages" do
      data = snapshot()
      [line] = data["lines"]

      lines =
        for n <- 1..60,
            do:
              Map.put(
                line,
                "description",
                "Service-#{n}-end " <> String.duplicate("Consulting and documentation. ", 4)
              )

      assert {:ok, bytes} = Pdf.render(Map.put(data, "lines", lines))
      text = pdf_text(bytes)
      for n <- 1..60, do: assert(text =~ "Service-#{n}-end")
      assert length(String.split(text, "\f")) > 2
    end

    test "credit note includes the original invoice number and date" do
      data =
        Map.merge(snapshot(), %{
          "document_type" => "credit_note",
          "number" => "CN/26-27/001",
          "original_invoice_number" => "INV/26-27/001",
          "original_invoice_date" => "2026-09-20"
        })

      assert {:ok, bytes} = Pdf.render(data)
      text = pdf_text(bytes)
      assert text =~ "CREDIT NOTE"
      assert text =~ "INV/26-27/001"
      assert text =~ "2026-09-20"
    end

    test "rejects malformed snapshots" do
      assert {:error, :invalid_invoice_snapshot} = Pdf.render(%{})
    end

    test "terminates an expired compile" do
      Application.put_env(:nila, Pdf, timeout: 0)
      assert {:error, :pdf_render_timeout} = Pdf.render(snapshot())
    end
  end

  defp pdf_text(bytes) do
    path = Path.join(System.tmp_dir!(), "nila-pdf-test-#{Ecto.UUID.generate()}.pdf")

    try do
      File.write!(path, bytes)
      {text, 0} = System.cmd("pdftotext", ["-layout", path, "-"], stderr_to_stdout: true)
      text
    after
      File.rm(path)
    end
  end

  defp snapshot do
    %{
      "number" => "INV/26-27/001",
      "document_type" => "invoice",
      "invoice_date" => "2026-09-22",
      "due_date" => "2026-10-22",
      "notes" => "Thank you for your business.",
      "supplier" => %{
        "name" => "Northstar Services",
        "address" => "12 Anna Salai, Chennai 600032",
        "gstin" => "33AAACC1206D1ZM",
        "state_code" => "33"
      },
      "customer" => %{
        "name" => "Example Customer",
        "address" => "14 Beach Road, Chennai 600001",
        "gstin" => "33AAACC1206D1ZM",
        "state_code" => "33"
      },
      "place_of_supply" => "33",
      "original_invoice_number" => nil,
      "lines" => [
        %{
          "description" => "Monthly consulting",
          "sac" => "998311",
          "quantity" => "1",
          "unit_price" => "1234.57",
          "taxable_paise" => 123_457,
          "cgst_paise" => 11111,
          "sgst_paise" => 11111,
          "igst_paise" => 0,
          "gst_rate" => "18"
        }
      ],
      "totals" => %{
        "taxable_paise" => 123_457,
        "cgst_paise" => 11111,
        "sgst_paise" => 11111,
        "igst_paise" => 0,
        "total_paise" => 145_679
      }
    }
  end
end
