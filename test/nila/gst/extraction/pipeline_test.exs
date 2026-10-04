defmodule Nila.Gst.Extraction.PipelineTest do
  alias Nila.Gst.Extraction.Sales.Normalizer
  alias Nila.Gst.Sales.Invoice
  use ExUnit.Case, async: true

  alias Nila.Gst.Extraction.Providers.OpenAICompatibleChat
  alias Nila.Gst.Extraction.InvoiceRepairs
  alias Nila.Gst.Extraction.Pipeline
  alias Nila.Gst.Purchase.Books
  alias Nila.PdfFixtures

  @line_item_fields ~w(
    item_name description hsn_sac quantity uom printed_unit_price discount_rate
    discount_amount printed_line_amount printed_line_total printed_taxable_value
    line_amount_tax_inclusion printed_tax_components repeat_count
  )

  defp chat_response(content) do
    %{
      "choices" => [%{"message" => %{"content" => Jason.encode!(content)}}],
      "usage" => %{"total_tokens" => 40}
    }
  end

  defp invoice(number \\ "INV-1") do
    %{
      "document_type" => "invoice",
      "invoice_number" => number,
      "invoice_date" => "08/10/2025",
      "seller" => %{
        "name" => "Supplier",
        "gstin" => "32AAMFD7558A1ZL",
        "address" => "Kerala"
      },
      "buyer" => %{"name" => "Breeze", "gstin" => "33AEWPH4158J1Z3"},
      "delivery_address" => nil,
      "line_items" => [],
      "printed_subtotal_before_discount" => nil,
      "printed_discount_amount" => nil,
      "printed_total_taxable" => 1_000.0,
      "printed_tax_totals" => [
        %{"printed_label" => "CGST", "printed_amount" => 90.0},
        %{"printed_label" => "SGST", "printed_amount" => 90.0},
        %{"printed_label" => "Total Tax", "printed_amount" => 180.0}
      ],
      "printed_additional_charges" => nil,
      "printed_rounding_adjustment" => nil,
      "printed_grand_total" => 1_180.0,
      "reverse_charge" => nil
    }
  end

  defp sales_invoice do
    invoice()
    |> Map.drop(["seller", "buyer", "delivery_address"])
    |> Map.merge(%{
      "supplier" => %{
        "name" => "Breeze",
        "gstin" => "33AEWPH4158J1Z3",
        "address" => "Chennai",
        "state_code" => "33"
      },
      "bill_to" => %{
        "name" => "Customer",
        "gstin" => "33AAHFC9048D1Z4",
        "address" => "Chennai",
        "state_code" => "33"
      },
      "ship_to" => nil,
      "recipient_registration" => "registered",
      "document_status" => "active",
      "supply_type" => "taxable",
      "tax_payment" => "not_applicable"
    })
  end

  defp line_item(overrides) do
    Map.merge(
      %{
        "item_name" => "CAMC for Chiller",
        "description" => "CAMC for Chiller",
        "hsn_sac" => "998719",
        "quantity" => 1,
        "uom" => nil,
        "printed_unit_price" => 47_500,
        "discount_rate" => nil,
        "discount_amount" => nil,
        "printed_line_amount" => 47_500,
        "printed_line_total" => 56_050,
        "printed_taxable_value" => nil,
        "line_amount_tax_inclusion" => "exclusive",
        "printed_tax_components" => [
          %{"printed_label" => "CGST", "printed_rate" => 9, "printed_amount" => 4_275},
          %{"printed_label" => "SGST", "printed_rate" => 9, "printed_amount" => 4_275}
        ],
        "repeat_count" => 1
      },
      overrides
    )
  end

  defp positional_line_item(overrides) do
    line = line_item(overrides)
    Enum.map(@line_item_fields, &Map.fetch!(line, &1))
  end

  defp stub(labels, extracted_invoice \\ invoice()) do
    test_pid = self()

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      name = get_in(request, ["response_format", "json_schema", "name"])
      send(test_pid, {:vision_request, name, request})

      content =
        if name == "nila_packet_page_labels", do: %{"pages" => labels}, else: extracted_invoice

      Req.Test.json(conn, chat_response(content))
    end)
  end

  test "semantic amounts reach accounting before repairs for both text and image input" do
    row = [
      "Part",
      nil,
      "854110",
      10,
      "PCS",
      100,
      nil,
      nil,
      nil,
      1180,
      [%{"printed_label" => "GST", "printed_rate" => 18, "printed_amount" => 180}],
      1
    ]

    stub([], Map.put(sales_invoice(), "line_items", [row]))

    for input <- [:text, :vision] do
      assert {:ok, result} =
               Pipeline.extract_fixed_segments(
                 :sales,
                 PdfFixtures.text_pdf(["Tax Invoice INV-1 Amount 1180 GST 180"]),
                 [[1]],
                 input: input,
                 contract: :semantic
               )

      assert [artifact] = result.pages
      assert [line] = artifact["data"]["line_items"]
      assert line["printed_line_total"] == 1180
      assert line["printed_taxable_value"] == nil
      assert [normalized] = Normalizer.normalize(artifact)["line_items"]
      assert normalized["taxable_value"] == 1000
      assert result.audit.metadata["contract"] == "semantic"
    end
  end

  test "reports completed invoices through the callback with stable segment ordinals" do
    stub(
      [
        %{
          "page" => 1,
          "page_role" => "start",
          "document_type" => "tax_invoice",
          "invoice_no" => "INV-1",
          "reason" => nil
        },
        %{
          "page" => 2,
          "page_role" => "start",
          "document_type" => "tax_invoice",
          "invoice_no" => "INV-2",
          "reason" => nil
        }
      ],
      sales_invoice()
    )

    test_pid = self()

    assert {:ok, _result} =
             Pipeline.extract(
               :sales,
               PdfFixtures.text_pdf(["Invoice INV-1", "Invoice INV-2"]),
               input: :text,
               on_invoice: fn artifact, ordinal, _evidence ->
                 send(test_pid, {:invoice_ready, artifact["page"], ordinal})
               end
             )

    messages =
      for _ <- 1..2 do
        assert_receive {:invoice_ready, page, ordinal}
        {page, ordinal}
      end

    assert Enum.sort(messages) == [{1, 1}, {2, 2}]
  end

  test "publishes the fast invoice while the first call is paused and resumes without reading it again" do
    owner = self()

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      if String.contains?(body, "SLOW-INVOICE") do
        send(owner, {:slow_call, self()})

        receive do
          :release -> :ok
        after
          5_000 -> raise "slow call was not released"
        end
      end

      Req.Test.json(conn, chat_response(sales_invoice()))
    end)

    pdf = PdfFixtures.text_pdf(["SLOW-INVOICE", "FAST-INVOICE"])

    start_supervised!(
      {Task,
       fn ->
         Req.Test.allow(OpenAICompatibleChat, owner, self())

         result =
           Pipeline.extract_fixed_segments(:sales, pdf, [[1], [2]],
             input: :text,
             on_invoice: fn artifact, ordinal, _ ->
               send(owner, {:completed, ordinal, artifact})
             end
           )

         send(owner, {:finished, result})
       end}
    )

    assert_receive {:slow_call, slow}, 5_000
    assert_receive {:completed, 2, fast}, 5_000
    refute_received {:finished, _}
    send(slow, :release)
    assert_receive {:completed, 1, _}, 5_000
    assert_receive {:finished, {:ok, result}}, 5_000
    assert Enum.map(result.pages, & &1["page"]) == [1, 2]

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      refute String.contains?(body, "FAST-INVOICE")
      Req.Test.json(conn, chat_response(sales_invoice()))
    end)

    assert {:ok, resumed} =
             Pipeline.extract_fixed_segments(:sales, pdf, [[1], [2]],
               input: :text,
               completed_artifacts: %{"2" => fast}
             )

    assert Enum.map(resumed.pages, & &1["page"]) == [1, 2]
  end

  test "native sales text uses the same artifact contract and retains review images and text evidence" do
    stub(
      [
        %{
          "page" => 1,
          "page_role" => "start",
          "document_type" => "tax_invoice",
          "invoice_no" => "INV-1",
          "reason" => nil
        },
        %{
          "page" => 2,
          "page_role" => "continuation",
          "document_type" => nil,
          "invoice_no" => nil,
          "reason" => nil
        }
      ],
      put_in(sales_invoice(), ["supplier", "gstin"], "33AEWPH4158J1ZZ")
    )

    pdf = PdfFixtures.text_pdf(["GSTIN 33AEWPH4158J1Z3 Invoice INV-1", "Continued total 1180"])

    assert {:ok, result} =
             Pipeline.extract(:sales, pdf, input: :text, client_gstin: "33AEWPH4158J1Z3")

    assert [%{"source_pages" => [1, 2], "image" => "page_01.jpg"} = artifact] = result.pages
    assert Normalizer.normalize(artifact)["invoice_number"] == "INV-1"
    assert Normalizer.normalize(artifact)["seller_gstin"] == "33AEWPH4158J1Z3"

    assert artifact["data"]["seller_identity"] == %{
             "client_gstin" => "33AEWPH4158J1Z3",
             "observed_gstin" => "33AEWPH4158J1ZZ",
             "source_gstin" => "33AEWPH4158J1Z3",
             "status" => "matched"
           }

    refute Enum.any?(
             artifact["verification"]["failed_checks"],
             &(&1["field"] == "supplier.gstin")
           )

    assert map_size(result.images) == 2
    assert result.audit.metadata["native_text"]["1"] =~ "33AEWPH4158J1Z3"
    assert result.audit.metadata["invoice_inputs"] == [%{"pages" => [1, 2], "input" => "text"}]

    assert_receive {:vision_request, "nila_packet_page_labels", labels}
    assert_receive {:vision_request, "nila_sales_invoice", invoice}

    for request <- [labels, invoice] do
      [_system, %{"content" => content}] = request["messages"]
      assert Enum.all?(content, &(&1["type"] == "text"))
      assert Enum.any?(content, &String.contains?(&1["text"], "33AEWPH4158J1Z3"))
      assert Enum.any?(content, &String.contains?(&1["text"], "Continued total 1180"))
    end
  end

  test "an included earlier page keeps saved segment order and reads only the new invoice" do
    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      Req.Test.json(conn, chat_response(sales_invoice()))
    end)

    pdf = PdfFixtures.text_pdf(["NEW-INVOICE", "SAVED-INVOICE"])
    assert {:ok, first} = Pipeline.extract_fixed_segments(:sales, pdf, [[2]], input: :text)
    [saved] = first.pages
    owner = self()

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert String.contains?(body, "NEW-INVOICE")
      refute String.contains?(body, "SAVED-INVOICE")
      send(owner, :new_invoice_read)
      Req.Test.json(conn, chat_response(sales_invoice()))
    end)

    segments =
      Enum.map(
        [[2], [1]],
        &%{"kind" => "invoice", "pages" => &1, "document_type" => "tax_invoice"}
      )

    assert {:ok, result} =
             Pipeline.extract(:sales, pdf,
               input: :text,
               resume_segments: segments,
               completed_artifacts: %{"1" => saved},
               on_segments: fn segments -> send(owner, {:segments, segments}) end,
               on_invoice: fn artifact, ordinal, _ ->
                 send(owner, {:invoice, ordinal, artifact["source_pages"]})
               end
             )

    assert_receive :new_invoice_read
    refute_received :new_invoice_read
    assert_receive {:segments, [%{"pages" => [2]}, %{"pages" => [1]}]}
    assert_receive {:invoice, 1, [2]}
    assert_receive {:invoice, 2, [1]}
    assert Enum.map(result.pages, & &1["source_pages"]) == [[1], [2]]
  end

  test "a scanned continuation retains the complete invoice in vision" do
    stub(
      [
        %{
          "page" => 1,
          "page_role" => "start",
          "document_type" => "tax_invoice",
          "invoice_no" => "INV-1",
          "reason" => nil
        },
        %{
          "page" => 2,
          "page_role" => "continuation",
          "document_type" => nil,
          "invoice_no" => nil,
          "reason" => nil
        }
      ],
      sales_invoice()
    )

    assert {:ok, result} =
             Pipeline.extract(:sales, PdfFixtures.text_pdf(["Invoice INV-1", ""]), input: :text)

    assert result.audit.metadata["invoice_inputs"] == [%{"pages" => [1, 2], "input" => "vision"}]
    assert_receive {:vision_request, "nila_packet_page_labels", labels}
    assert_receive {:vision_request, "nila_sales_invoice", invoice}
    assert Enum.count(List.last(labels["messages"])["content"], &(&1["type"] == "image_url")) == 1

    assert Enum.count(List.last(invoice["messages"])["content"], &(&1["type"] == "image_url")) ==
             2
  end

  test "a sales proforma stays outside invoice extraction with its source text in the audit" do
    stub(
      [
        %{
          "page" => 1,
          "page_role" => "start",
          "document_type" => "proforma_invoice",
          "invoice_no" => "PF-1",
          "reason" => "Proforma invoice"
        }
      ],
      sales_invoice()
    )

    test_pid = self()

    per_call = fn metadata, call ->
      result = call.()
      send(test_pid, {:audited_result, metadata.stage, result})
      result
    end

    assert {:ok, %{pages: [], excluded_documents: [%{"document_type" => "proforma_invoice"}]}} =
             Pipeline.extract(:sales, PdfFixtures.text_pdf(["PROFORMA INVOICE PF-1"]),
               input: :text,
               per_call: per_call
             )

    assert_receive {:vision_request, "nila_packet_page_labels", request}

    assert hd(List.last(request["messages"])["content"])["text"] =~
             "Its terms page is continuation"

    refute_receive {:vision_request, "nila_sales_invoice", _}
    assert_receive {:audited_result, "text_segmentation", {:ok, %{audit: audit}}}
    assert audit.metadata["native_text"]["1"] =~ "PROFORMA INVOICE PF-1"
  end

  test "fixed-page text extraction keeps blank-page vision fallback and purchase scope unchanged" do
    stub([], sales_invoice())

    assert {:ok, result} =
             Pipeline.extract_fixed_segments(:sales, PdfFixtures.pdf(1), [[1]], input: :text)

    assert result.audit.metadata["invoice_inputs"] == [%{"pages" => [1], "input" => "vision"}]
    assert_receive {:vision_request, "nila_sales_invoice", request}
    assert Enum.any?(List.last(request["messages"])["content"], &(&1["type"] == "image_url"))

    assert {:error, {:unsupported_extraction_input, :purchase, :text}} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(1), input: :text)
  end

  test "a proforma continuation cannot become a fabricated sales invoice" do
    stub(
      [
        %{
          "page" => 1,
          "page_role" => "start",
          "document_type" => "proforma_invoice",
          "invoice_no" => "PF-1",
          "reason" => "Proforma"
        },
        %{
          "page" => 2,
          "page_role" => "continuation",
          "document_type" => nil,
          "invoice_no" => nil,
          "reason" => "Terms of proforma"
        }
      ],
      sales_invoice()
    )

    assert {:ok, result} =
             Pipeline.extract(
               :sales,
               PdfFixtures.text_pdf(["PROFORMA INVOICE PF-1", "Terms and conditions"]),
               input: :text
             )

    assert result.pages == []

    assert [%{"pages" => [1, 2], "document_type" => "proforma_invoice", "invoice_no" => "PF-1"}] =
             result.excluded_documents

    assert map_size(result.images) == 2
    assert result.unaccounted_pages == [1, 2]
    assert_receive {:vision_request, "nila_packet_page_labels", _}
    refute_receive {:vision_request, "nila_sales_invoice", _}
  end

  test "a mixed sales packet extracts only the invoice after grouping the whole quotation" do
    stub(
      [
        %{
          "page" => 1,
          "page_role" => "start",
          "document_type" => "quotation",
          "invoice_no" => "Q-1",
          "reason" => "Quotation"
        },
        %{
          "page" => 2,
          "page_role" => "continuation",
          "document_type" => nil,
          "invoice_no" => nil,
          "reason" => "Terms"
        },
        %{
          "page" => 3,
          "page_role" => "start",
          "document_type" => "tax_invoice",
          "invoice_no" => "INV-1",
          "reason" => nil
        }
      ],
      sales_invoice()
    )

    assert {:ok, result} =
             Pipeline.extract(
               :sales,
               PdfFixtures.text_pdf(["QUOTATION Q-1", "Quotation terms", "TAX INVOICE INV-1"]),
               input: :text
             )

    assert [artifact] = result.pages
    assert artifact["source_pages"] == [3]
    assert [%{"pages" => [1, 2], "document_type" => "quotation"}] = result.excluded_documents
    assert_receive {:vision_request, "nila_sales_invoice", request}
    payload = Jason.encode!(List.last(request["messages"])["content"])
    assert payload =~ "TAX INVOICE INV-1"
    refute payload =~ "Quotation terms"
    refute payload =~ "QUOTATION Q-1"
    refute_receive {:vision_request, "nila_sales_invoice", _}
  end

  test "segments a PDF once and extracts one artifact from the resulting page group" do
    stub([
      %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil},
      %{"page" => 2, "label" => "continuation", "invoice_no" => nil, "reason" => nil}
    ])

    test_pid = self()

    per_call = fn metadata, call ->
      send(test_pid, {:stage, metadata})
      call.()
    end

    assert {:ok, result} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(2),
               filename: "packet.pdf",
               client_gstin: "33AEWPH4158J1Z3",
               per_call: per_call,
               on_progress: &send(test_pid, &1)
             )

    assert [%{"source_pages" => [1, 2]} = artifact] = result.pages
    assert artifact["data"]["invoice_number"] == "INV-1"
    assert artifact["image"] == "page_01.jpg"
    assert artifact["verification"]["status"] == "unverifiable"
    assert map_size(result.images) == 2
    assert result.unaccounted_pages == []

    assert %{"invoices" => [%{"taxable_paise" => 100_000, "total_paise" => 118_000}]} =
             Books.normalize(result.pages)

    assert_receive {:stage, %{stage: "vision_segmentation", pages: 2}}
    assert_receive {:stage, %{stage: "vision_extraction", segments: 1}}
    assert_receive {:progress, %{stage: :segmenting, done: 2, total: 2}}
    assert_receive {:progress, %{stage: :reading, done: 1, total: 1}}

    assert_receive {:vision_request, "nila_packet_page_labels", segmentation_request}
    [_system, %{"content" => segmentation_content}] = segmentation_request["messages"]
    assert Enum.count(segmentation_content, &(&1["type"] == "image_url")) == 2

    assert_receive {:vision_request, "nila_purchase_invoice", extraction_request}

    line_schema =
      get_in(extraction_request, [
        "response_format",
        "json_schema",
        "schema",
        "properties",
        "line_items",
        "items"
      ])

    assert line_schema["type"] == "array"
    assert line_schema["items"] == false
    assert line_schema["minItems"] == length(@line_item_fields)
    assert length(line_schema["prefixItems"]) == length(@line_item_fields)

    component_schema = Enum.at(line_schema["prefixItems"], 12)
    assert component_schema["type"] == "array"

    assert MapSet.new(component_schema["items"]["required"]) ==
             MapSet.new(~w(printed_amount printed_label printed_rate))

    assert component_schema["description"] =~ "Copy each label"

    root_properties = extraction_request["response_format"]["json_schema"]["schema"]["properties"]
    assert Map.has_key?(root_properties, "printed_tax_totals")
    assert root_properties["line_items"]["description"] =~ "append it to that item's description"

    assert MapSet.new(root_properties["printed_tax_totals"]["items"]["required"]) ==
             MapSet.new(~w(printed_amount printed_label))

    refute Map.has_key?(root_properties, "printed_cgst")
    refute Map.has_key?(root_properties, "printed_sgst")
    refute Map.has_key?(root_properties, "printed_igst")

    [_system, %{"content" => extraction_content}] = extraction_request["messages"]
    assert Enum.count(extraction_content, &(&1["type"] == "image_url")) == 2
    instruction = hd(extraction_content)["text"]
    assert instruction =~ "[#{Enum.join(@line_item_fields, ", ")}]"
    assert instruction =~ "Preserve nulls so every row has exactly"
    assert instruction =~ "14 values"
  end

  test "one failed invoice call rejects the whole packet and preserves completed responses" do
    test_pid = self()

    Req.Test.stub(OpenAICompatibleChat, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      name = get_in(request, ["response_format", "json_schema", "name"])

      case name do
        "nila_packet_page_labels" ->
          Req.Test.json(
            conn,
            chat_response(%{
              "pages" => [
                %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil},
                %{"page" => 2, "label" => "start", "invoice_no" => "INV-2", "reason" => nil}
              ]
            })
          )

        "nila_purchase_invoice" ->
          [_system, %{"content" => content}] = request["messages"]
          marker = Enum.find(content, &(&1["type"] == "text" and &1["text"] =~ "PHYSICAL PAGE"))

          if marker["text"] == "PHYSICAL PAGE 2" do
            conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "bad page"})
          else
            Req.Test.json(conn, chat_response(invoice()))
          end
      end
    end)

    per_call = fn metadata, call ->
      result = call.()
      send(test_pid, {:stage_result, metadata.stage, result})
      result
    end

    assert {:error, {:invoice_segments_failed, [%{pages: [2]}]}} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(2),
               filename: "packet.pdf",
               max_retries: 0,
               per_call: per_call
             )

    assert_receive {:stage_result, "vision_extraction", {:error, _reason, audit}}
    assert length(audit.metadata["responses"]) == 2
    assert audit.metadata["failures"] != []
  end

  test "rejects a segmentation response that does not conserve every physical page" do
    stub([
      %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil}
    ])

    assert {:error, {:page_conservation, [1, 2], [1]}} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(2), filename: "packet.pdf")

    assert_receive {:vision_request, "nila_packet_page_labels", _request}
    refute_receive {:vision_request, "nila_purchase_invoice", _request}
  end

  test "sales uses the sales schema and preserves vision document markers" do
    stub(
      [
        %{
          "page" => 1,
          "page_role" => "start",
          "document_type" => "tax_invoice",
          "invoice_no" => "INV-1",
          "reason" => nil
        }
      ],
      Map.put(sales_invoice(), "reverse_charge", true)
    )

    assert {:ok, %{pages: [artifact]}} =
             Pipeline.extract(:sales, <<0xFF, 0xD8, 0xFF, 0xD9>>,
               filename: "sale.jpg",
               client_gstin: "33AEWPH4158J1Z3"
             )

    assert artifact["document"] == %{
             "credit_note" => false,
             "debit_note" => false,
             "export" => false,
             "reverse_charge" => true,
             "extracted_type" => "invoice"
           }

    assert artifact["data"]["recipient_registration"] == "registered"
  end

  test "fixed-segment extraction skips discovery but retains the production vision path" do
    stub([], sales_invoice())

    assert {:ok, %{pages: [artifact]}} =
             Pipeline.extract_fixed_segments(
               :sales,
               <<0xFF, 0xD8, 0xFF, 0xD9>>,
               [[1]],
               filename: "sale.jpg",
               client_gstin: "33AEWPH4158J1Z3"
             )

    assert artifact["data"]["invoice_number"] == "INV-1"
    assert_receive {:vision_request, "nila_sales_invoice", _request}
    refute_receive {:vision_request, "nila_packet_page_labels", _request}
  end

  test "expands repeated rows before verification and sales accounting" do
    extracted =
      sales_invoice()
      |> put_in(
        ["bill_to"],
        %{
          "name" => "Customer",
          "gstin" => "29AAVCS8021P1ZB",
          "address" => "Karnataka",
          "state_code" => "29"
        }
      )
      |> Map.put("line_items", [positional_line_item(%{"repeat_count" => 10})])
      |> Map.merge(%{
        "printed_subtotal_before_discount" => 475_000,
        "printed_total_taxable" => 475_000,
        "printed_tax_totals" => [
          %{
            "printed_label" => "CGST",
            "printed_amount" => 42_750
          },
          %{
            "printed_label" => "SGST",
            "printed_amount" => 42_750
          },
          %{
            "printed_label" => "Total Tax",
            "printed_amount" => 85_500
          }
        ],
        "printed_grand_total" => 560_500
      })

    stub(
      [
        %{
          "page" => 1,
          "page_role" => "start",
          "document_type" => "tax_invoice",
          "invoice_no" => "27/2026-27",
          "reason" => nil
        }
      ],
      extracted
    )

    assert {:ok, %{pages: [artifact]}} =
             Pipeline.extract(:sales, <<0xFF, 0xD8, 0xFF, 0xD9>>, filename: "sale.jpg")

    assert lines = artifact["data"]["line_items"]
    assert length(lines) == 10
    assert Enum.all?(lines, &(&1["item_name"] == "CAMC for Chiller"))
    assert Enum.all?(lines, &(not Map.has_key?(&1, "repeat_count")))
    assert Enum.all?(lines, &(&1["cgst_rate"] == 9 and &1["sgst_rate"] == 9))
    assert artifact["verification"]["flags"] == []

    normalized = Normalizer.normalize(artifact)
    assert Invoice.extracted_totals(normalized) == %{taxable: 475_000, tax: 85_500}
    assert normalized["printed_grand_total"] == 560_500

    assert Enum.all?(
             normalized["line_items"],
             &(&1["printed_tax_components"] == [
                 %{
                   "printed_label" => "CGST",
                   "printed_rate" => 9,
                   "printed_amount" => 4_275
                 },
                 %{
                   "printed_label" => "SGST",
                   "printed_rate" => 9,
                   "printed_amount" => 4_275
                 }
               ])
           )
  end

  test "does not collapse distinct or non-consecutive rows" do
    data = %{
      "line_items" => [
        line_item(%{"item_name" => "First", "repeat_count" => 1}),
        line_item(%{"item_name" => "Second", "repeat_count" => 1}),
        line_item(%{"item_name" => "First", "repeat_count" => 1})
      ]
    }

    assert %{"line_items" => lines} = InvoiceRepairs.expand_repeated_line_items(data)
    assert Enum.map(lines, & &1["item_name"]) == ["First", "Second", "First"]
    assert Enum.all?(lines, &(not Map.has_key?(&1, "repeat_count")))
  end

  test "rejects a repeat count outside the schema boundary" do
    data = %{"line_items" => [line_item(%{"repeat_count" => 1_001})]}

    assert_raise ArgumentError, "invalid repeat_count: 1001", fn ->
      InvoiceRepairs.expand_repeated_line_items(data)
    end
  end

  test "reports model-proposed non-invoices as unaccounted without independent proof" do
    stub([
      %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil},
      %{"page" => 2, "label" => "non_invoice", "invoice_no" => nil, "reason" => "receipt"}
    ])

    assert {:ok, result} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(2), filename: "packet.pdf")

    assert result.unaccounted_pages == [2]
  end

  test "sends an uploaded image directly and retains it as review evidence" do
    stub([
      %{"page" => 1, "label" => "start", "invoice_no" => "INV-1", "reason" => nil}
    ])

    jpeg = <<0xFF, 0xD8, 0xFF, 0xD9>>

    assert {:ok, %{pages: [artifact], images: %{"page_01.jpg" => ^jpeg}}} =
             Pipeline.extract(:purchase, jpeg, filename: "scan.jpg")

    assert artifact["source_pages"] == [1]
    assert artifact["image"] == "page_01.jpg"

    assert_receive {:vision_request, "nila_packet_page_labels", request}
    [_system, %{"content" => content}] = request["messages"]
    image = Enum.find(content, &(&1["type"] == "image_url"))
    assert image["image_url"]["url"] =~ "data:image/jpeg;base64,"
  end

  test "bounds whole-packet segmentation before submitting images to the provider" do
    assert {:error, {:vision_packet_too_many_pages, 101, 100}} =
             Pipeline.extract(:purchase, PdfFixtures.pdf(101), filename: "packet.pdf")
  end

  test "rejects image formats the gateway and evidence UI cannot safely preserve" do
    assert {:error, {:unsupported_content_type, "image/heic"}} =
             Pipeline.extract(:purchase, "heic", filename: "scan.heic")
  end
end
