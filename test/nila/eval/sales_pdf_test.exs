defmodule Nila.Eval.SalesPdfTest do
  use ExUnit.Case, async: true

  alias Nila.Eval.SalesPdf
  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat

  test "a source with no invoice stays visible in month issues and cannot become filing-ready" do
    root = Path.join(System.tmp_dir!(), "nila-sales-eval-#{Ecto.UUID.generate()}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, "proforma.pdf")
    File.write!(path, Nila.PdfFixtures.text_pdf(["PROFORMA INVOICE PF-1"]))

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert get_in(request, ["response_format", "json_schema", "name"]) ==
               "nila_packet_page_labels"

      labels = %{
        "pages" => [
          %{
            "page" => 1,
            "page_role" => "start",
            "document_type" => "proforma_invoice",
            "invoice_no" => "PF-1",
            "reason" => "Proforma"
          }
        ]
      }

      Req.Test.json(conn, %{"choices" => [%{"message" => %{"content" => Jason.encode!(labels)}}]})
    end)

    assert {:ok, summary} =
             SalesPdf.run([path], %{name: "Example", gstin: "33AEWPH4158J1Z3"}, "2026-08",
               output_root: root
             )

    assert summary.source_files == 1
    assert summary.extracted_files == 1
    assert summary.failures == []
    assert summary.invoice_count == 0
    refute summary.filing_ready
    assert summary.gating_issues > 0
    assert summary.workbook == "no_invoices"
    issues = summary.directory |> Path.join("issues.json") |> File.read!() |> Jason.decode!()

    assert Enum.any?(
             issues,
             &(&1["code"] == "pages_unaccounted" and
                 String.contains?(&1["message"], "proforma.pdf"))
           )

    assert Enum.any?(issues, &String.contains?(&1["message"], "proforma_invoice"))
    assert File.exists?(Path.join(summary.directory, "001/page_01.jpg"))

    audit =
      summary.directory
      |> Path.join("001/text_segmentation.json")
      |> File.read!()
      |> Jason.decode!()

    assert audit["metadata"]["native_text"]["1"] =~ "PROFORMA INVOICE PF-1"
  end
end
