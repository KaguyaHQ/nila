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

    test "goods quotation prints HSN, unit, customer state and ship-to address" do
      data =
        Map.merge(snapshot(), %{
          "document_type" => "quotation",
          "number" => "QT/2627/0002",
          "delivery_address" => "Parvathi Hospital, Chennai",
          "shipping_name" => "Parvathi Hospital",
          "shipping_gstin" => "33AAACG0123F1ZK"
        })

      [line] = data["lines"]

      data =
        Map.put(data, "lines", [
          Map.merge(line, %{
            "description" => "Refrigerant gas",
            "kind" => "goods",
            "sac" => "290339",
            "unit" => "KGS"
          })
        ])

      assert {:ok, bytes} = Pdf.render(data)
      text = pdf_text(bytes)
      assert text =~ "Refrigerant gas"
      assert text =~ "HSN/SAC"
      assert text =~ "290339"
      assert text =~ "KGS"
      assert text =~ "State 33"
      assert text =~ "SHIP TO"
      assert text =~ "Parvathi Hospital"
      assert text =~ "Parvathi Hospital, Chennai"
      assert text =~ "33AAACG0123F1ZK"
    end

    test "quotation includes business branding, work title and revision reference" do
      image = File.read!("priv/static/images/og-image.png")
      logo_key = "test/business-logo-#{Ecto.UUID.generate()}.png"
      signature_key = "test/business-signature-#{Ecto.UUID.generate()}.png"
      {:ok, _} = Nila.Storage.put(logo_key, image, content_type: "image/png")
      {:ok, _} = Nila.Storage.put(signature_key, image, content_type: "image/png")

      on_exit(fn ->
        Nila.Storage.delete(logo_key)
        Nila.Storage.delete(signature_key)
      end)

      data =
        snapshot()
        |> Map.merge(%{
          "document_type" => "quotation",
          "number" => "79/2026-27",
          "subject" => "Compressor and Pipe Supply and Insulation",
          "delivery_address" => "IndiraGandhi Hospital, Puducherry",
          "delivery_state_code" => "34",
          "revised_from_number" => "78/2026-27"
        })
        |> Map.update!("lines", fn [line] ->
          for description <- [
                "Compressor replacement",
                "Labour and installation",
                "Copper pipe",
                "Insulation foam",
                "R32 refrigerant gas",
                "Transport"
              ],
              do: Map.put(line, "description", description)
        end)
        |> Map.put("totals", %{
          "taxable_paise" => 740_742,
          "cgst_paise" => 66_666,
          "sgst_paise" => 66_666,
          "igst_paise" => 0,
          "total_paise" => 874_074
        })
        |> put_in(["supplier", "phone"], "9962550448")
        |> put_in(["supplier", "email"], "quotes@example.com")
        |> put_in(["supplier", "logo_key"], logo_key)
        |> put_in(["supplier", "signature_key"], signature_key)

      assert {:ok, bytes} = Pdf.render(data)
      text = pdf_text(bytes)
      assert text =~ "79/2026-27"
      assert text =~ "Revised from"
      assert text =~ "78/2026-27"
      assert text =~ "Compressor and Pipe Supply and Insulation"
      assert text =~ "9962550448"
      assert text =~ "quotes@example.com"
      assert text =~ "State 34"
      assert text =~ "R32 refrigerant gas"
      assert length(String.split(text, "\f")) == 2
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
