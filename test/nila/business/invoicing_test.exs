defmodule Nila.Business.InvoicingTest do
  use Nila.DataCase, async: true
  import Nila.AccountsFixtures
  alias Nila.Business.{Invoice, Invoicing}
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Derivation, Months}

  test "amount words support the upper line-value boundary", ctx do
    assert {:ok, %{total_in_words: words}} =
             Invoicing.calculate(
               ctx.client,
               %{
                 "place_of_supply" => "33",
                 "lines" => [
                   %{"quantity" => "1", "unit_price" => "1000000000", "gst_rate" => "18"}
                 ]
               }
             )

    assert words =~ "One Hundred Eighteen Crore"
  end

  test "reference and delivery details are retained in issued snapshot", ctx do
    attrs = %{
      "purchase_order_number" => "WO-4821",
      "purchase_order_date" => "2026-09-01",
      "delivery_address" => "Military Hospital Secunderabad\nTirumalagiri 500015"
    }

    {:ok, draft} = draft(ctx, attrs)
    assert {:ok, invoice} = issue(ctx, draft)
    assert invoice.snapshot["purchase_order_number"] == "WO-4821"
    assert invoice.snapshot["purchase_order_date"] == "2026-09-01"
    assert invoice.snapshot["delivery_address"] == attrs["delivery_address"]
    assert invoice.snapshot["total_in_words"] =~ "One Thousand One Hundred Eighty"

    assert {:error, :already_issued} =
             Invoicing.update_draft(ctx.client, invoice.id, ctx.actor, %{
               "purchase_order_number" => "CHANGED"
             })
  end

  test "customer addresses select buyer GSTIN and consignee without changing issued facts", ctx do
    [primary] = Invoicing.list_customer_addresses(ctx.client)
    assert primary.customer_id == ctx.customer.id
    assert primary.is_primary_billing

    {:ok, billing} =
      Invoicing.create_customer_address(ctx.client, ctx.customer.id, %{
        label: "Bengaluru Office",
        address: "Siemens, Bengaluru",
        state_code: "29",
        gstin: "29AAVCS8021P1ZB",
        usage: "billing"
      })

    {:ok, shipping} =
      Invoicing.create_customer_address(ctx.client, ctx.customer.id, %{
        label: "Apollo Hospital, Mysore",
        address: "Apollo Hospital, Mysore",
        state_code: "29",
        usage: "shipping"
      })

    {:ok, draft} =
      draft(ctx, %{
        "billing_address_id" => billing.id,
        "shipping_address_id" => shipping.id,
        "place_of_supply" => "29"
      })

    assert draft.billing_address_id == billing.id
    assert draft.shipping_address_id == shipping.id
    assert {:ok, issued} = issue(ctx, draft)
    assert issued.snapshot["customer"]["gstin"] == "29AAVCS8021P1ZB"
    assert issued.snapshot["customer"]["address"] == "Siemens, Bengaluru"
    assert issued.snapshot["delivery_address"] == "Apollo Hospital, Mysore"
    assert issued.snapshot["shipping_name"] == "Apollo Hospital, Mysore"

    assert {:ok, _} =
             Invoicing.update_customer_address(ctx.client, ctx.customer.id, billing.id, %{
               address: "Moved office"
             })

    assert {:ok, unchanged} = Invoicing.get_invoice(ctx.client, issued.id)
    assert unchanged.snapshot == issued.snapshot
  end

  test "selected addresses must belong to the customer and allow their selected role", ctx do
    {:ok, other} =
      Invoicing.create_customer(ctx.client, %{
        name: "Other buyer",
        address: "Delhi",
        state_code: "07"
      })

    other_address =
      Invoicing.list_customer_addresses(ctx.client)
      |> Enum.find(&(&1.customer_id == other.id))

    assert {:error, changeset} =
             draft(ctx, %{"billing_address_id" => other_address.id})

    assert :billing_address_id in Keyword.keys(changeset.errors)

    {:ok, shipping} =
      Invoicing.create_customer_address(ctx.client, ctx.customer.id, %{
        label: "Hospital",
        address: "Hospital, Chennai",
        state_code: "33",
        usage: "shipping"
      })

    assert {:error, changeset} = draft(ctx, %{"billing_address_id" => shipping.id})
    assert :billing_address_id in Keyword.keys(changeset.errors)
  end

  test "changing the primary billing address updates the customer default", ctx do
    [old_primary] = Invoicing.list_customer_addresses(ctx.client)

    {:ok, new_primary} =
      Invoicing.create_customer_address(ctx.client, ctx.customer.id, %{
        label: "Karnataka registration",
        address: "Bengaluru office",
        state_code: "29",
        gstin: "29AAVCS8021P1ZB",
        usage: "billing",
        is_primary_billing: true
      })

    addresses = Invoicing.list_customer_addresses(ctx.client)
    refute Enum.find(addresses, &(&1.id == old_primary.id)).is_primary_billing
    assert Enum.find(addresses, &(&1.id == new_primary.id)).is_primary_billing
    assert {:ok, customer} = Repo.fetch_by(Nila.Business.Customer, id: ctx.customer.id)
    assert customer.address == "Bengaluru office"
    assert customer.gstin == "29AAVCS8021P1ZB"
    assert {:ok, draft} = draft(ctx)
    assert draft.billing_address_id == new_primary.id
  end

  test "editable document amounts use issuance arithmetic before identity fields are complete",
       ctx do
    line = %{"quantity" => "2", "unit_price" => "500.50", "gst_rate" => "18"}

    assert {:ok, %{lines: [calculated], totals: totals}} =
             Invoicing.calculate(ctx.client, %{"place_of_supply" => "33", "lines" => [line]})

    assert calculated["taxable_paise"] == 100_100
    assert totals["cgst_paise"] == 9009
    assert totals["sgst_paise"] == 9009
    assert totals["total_paise"] == 118_118
    assert Invoicing.list_invoices(ctx.client) == []

    assert {:ok, %{totals: interstate}} =
             Invoicing.calculate(ctx.client, %{"place_of_supply" => "29", "lines" => [line]})

    assert interstate["igst_paise"] == 18_018
    assert interstate["cgst_paise"] == 0

    assert {:error, _} =
             Invoicing.calculate(ctx.client, %{"place_of_supply" => "invalid", "lines" => [line]})

    assert {:error, _} =
             Invoicing.calculate(ctx.client, %{
               "place_of_supply" => "33",
               "lines" => [Map.put(line, "unit_price", "")]
             })

    assert {:error, _} =
             Invoicing.calculate(ctx.client, %{"place_of_supply" => "33", "lines" => [nil]})
  end

  test "preview calculates unsaved edits without saving or allocating a number", ctx do
    attrs = %{
      "customer_id" => ctx.customer.id,
      "invoice_date" => "2026-09-22",
      "place_of_supply" => "29",
      "lines" => [
        %{
          "description" => "Preview service",
          "sac" => "998312",
          "quantity" => "2",
          "unit_price" => "500.50",
          "gst_rate" => "18"
        }
      ]
    }

    assert {:ok, "preview"} =
             Invoicing.preview(ctx.client, attrs,
               render_pdf: fn snapshot ->
                 assert snapshot["number"] == "DRAFT"
                 assert snapshot["draft"]
                 assert snapshot["totals"]["total_paise"] == 118_118
                 assert snapshot["totals"]["igst_paise"] == 18_018
                 {:ok, "preview"}
               end
             )

    assert Invoicing.list_invoices(ctx.client) == []
    assert Dumps.list(ctx.client.org_id, ctx.client.id, "2026-09") == []
    {:ok, draft} = draft(ctx)
    assert {:ok, %{number: "INV/2627/0001"}} = issue(ctx, draft)
  end

  test "preview rejects another business customer and invalid values before rendering", ctx do
    assert {:error, _} = Invoicing.preview(ctx.client, %{"customer_id" => 0})

    assert {:error, %Ecto.Changeset{}} =
             Invoicing.preview(
               ctx.client,
               %{"customer_id" => ctx.customer.id, "invoice_date" => "bad", "lines" => []}
             )
  end

  test "saved draft totals follow explicit POS and edited lines", ctx do
    {:ok, invoice} = draft(ctx)
    assert invoice.totals["total_paise"] == 118_000
    assert invoice.totals["cgst_paise"] == 9000

    assert {:ok, edited} =
             Invoicing.update_draft(ctx.client, invoice.id, ctx.actor, %{
               "place_of_supply" => "29",
               "lines" => [
                 %{
                   "description" => "Consulting",
                   "sac" => "998312",
                   "quantity" => "2",
                   "unit_price" => "500.50",
                   "gst_rate" => "18"
                 }
               ]
             })

    assert edited.totals == %{
             "taxable_paise" => 100_100,
             "igst_paise" => 18_018,
             "cgst_paise" => 0,
             "sgst_paise" => 0,
             "total_paise" => 118_118
           }
  end

  test "customer GSTIN can be cleared", ctx do
    {:ok, registered} =
      Invoicing.update_customer(ctx.client, ctx.customer.id, %{gstin: "33AABCP9487A1ZG"})

    assert registered.gstin == "33AABCP9487A1ZG"

    assert {:ok, %{gstin: nil}} =
             Invoicing.update_customer(ctx.client, registered.id, %{gstin: ""})
  end

  test "concurrent attempts on the same draft produce only one issued document", ctx do
    {:ok, invoice} = draft(ctx)
    owner = self()

    results =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, owner, self())
          issue(ctx, invoice)
        end)
      end
      |> Task.await_many(15_000)

    assert Enum.count(results, &match?({:ok, %Invoice{}}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :already_issued})) == 1
    assert length(Dumps.effective(ctx.client.org_id, ctx.client.id, "2026-09", "sales")) == 1
  end

  setup do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Service Business",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, _} =
      Invoicing.save_profile(client, %{
        legal_name: "Service Business",
        address: "Chennai",
        state_code: "33"
      })

    {:ok, customer} =
      Invoicing.create_customer(client, %{
        name: "Unregistered Customer",
        address: "Chennai",
        state_code: "33"
      })

    %{client: client, customer: customer, actor: user.id}
  end

  defp draft(ctx, overrides \\ %{}) do
    Invoicing.save_draft(
      ctx.client,
      ctx.actor,
      Map.merge(
        %{
          "customer_id" => ctx.customer.id,
          "invoice_date" => "2026-09-22",
          "place_of_supply" => "33",
          "lines" => [
            %{
              "description" => "Consulting",
              "sac" => "998312",
              "quantity" => "1",
              "unit_price" => "1000.00",
              "gst_rate" => "18"
            }
          ]
        },
        overrides
      )
    )
  end

  defp issue(ctx, invoice),
    do:
      Invoicing.issue(ctx.client, invoice.id, ctx.actor,
        render_pdf: fn snapshot -> {:ok, "%PDF-test " <> snapshot["number"]} end
      )

  test "invoice numbering continues the business series and direct issue is atomic", ctx do
    assert {:ok, numbering} =
             Invoicing.configure_invoice_numbering(ctx.client, %{
               "style" => "serial_fy",
               "next_number" => 129
             })

    assert numbering.next_number == 129
    assert numbering.style == "serial_fy"

    attrs = %{
      "customer_id" => ctx.customer.id,
      "invoice_date" => "2026-09-22",
      "place_of_supply" => "33",
      "lines" => [
        %{
          "description" => "Controller",
          "kind" => "goods",
          "sac" => "903290",
          "unit" => "NOS",
          "quantity" => "1",
          "unit_price" => "9000",
          "gst_rate" => "18"
        }
      ]
    }

    assert {:error, :renderer_down} =
             Invoicing.finalize_invoice(ctx.client, ctx.actor, attrs, nil,
               render_pdf: fn _ -> {:error, :renderer_down} end
             )

    assert Invoicing.list_invoices(ctx.client) == []
    assert Invoicing.invoice_numbering(ctx.client).next_number == 129

    assert {:ok, issued} =
             Invoicing.finalize_invoice(ctx.client, ctx.actor, attrs, nil,
               render_pdf: fn snapshot -> {:ok, "%PDF-test " <> snapshot["number"]} end
             )

    assert issued.number == "129/2026-27"
    assert issued.status == "issued"
    assert Invoicing.invoice_numbering(ctx.client).next_number == 130

    assert {:error, :numbering_started} =
             Invoicing.configure_invoice_numbering(ctx.client, %{
               "style" => "nila",
               "next_number" => 1
             })

    {:ok, draft} = draft(ctx)

    assert {:ok, next} =
             Invoicing.finalize_invoice(
               ctx.client,
               ctx.actor,
               %{
                 "customer_id" => ctx.customer.id,
                 "invoice_date" => "2026-09-22",
                 "place_of_supply" => "33",
                 "lines" => [
                   %{
                     "description" => "Revised service",
                     "sac" => "998312",
                     "quantity" => "1",
                     "unit_price" => "1000",
                     "gst_rate" => "18"
                   }
                 ]
               },
               draft.id,
               render_pdf: fn snapshot -> {:ok, "%PDF-test " <> snapshot["number"]} end
             )

    assert next.id == draft.id
    assert next.number == "130/2026-27"
    assert hd(next.snapshot["lines"])["description"] == "Revised service"
  end

  test "draft stays out of sales; issuance feeds CA working with saved source PDF and hash",
       ctx do
    assert {:ok, draft} = draft(ctx)

    assert {:error, :not_found} =
             Months.get_by_period(ctx.client.org_id, ctx.client.id, "2026-09")

    assert {:ok, invoice} = issue(ctx, draft)
    assert invoice.number == "INV/2627/0001"

    assert invoice.totals == %{
             "taxable_paise" => 100_000,
             "cgst_paise" => 9000,
             "sgst_paise" => 9000,
             "igst_paise" => 0,
             "total_paise" => 118_000
           }

    assert {:ok, bytes} = Invoicing.download(ctx.client, invoice.id)
    assert invoice.pdf_sha256 == Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    assert {:ok, month} = Months.get_by_period(ctx.client.org_id, ctx.client.id, "2026-09")
    assert [facts] = month.invoices
    assert facts["invoice_number"] == invoice.number
    assert facts["recipient_registration"] == "unregistered"
    assert facts["printed_grand_total"] == 1180
    assert [dump] = Dumps.effective(ctx.client.org_id, ctx.client.id, "2026-09", "sales")

    assert %{dump: %{id: source_dump_id}, batch_ref: batch_ref} =
             NilaWeb.Gst.InvoiceWorkbench.source_batch(
               ctx.client.org_id,
               ctx.client.id,
               "2026-09",
               facts["id"]
             )

    assert source_dump_id == dump.id
    assert batch_ref == to_string(dump.id)

    assert {:ok, _, _, ^bytes} =
             Dumps.fetch_original(ctx.client.org_id, ctx.client.id, "2026-09", dump.id, 0)

    Repo.transact(fn ->
      :ok = Derivation.refresh_in_transaction(dump)
      {:ok, :refreshed}
    end)

    assert {:ok, refreshed} = Months.get_by_period(ctx.client.org_id, ctx.client.id, "2026-09")
    assert length(refreshed.invoices) == 1
  end

  test "issued invoice cannot be reissued or edited, and profile/customer edits do not change its PDF",
       ctx do
    {:ok, draft} = draft(ctx)
    {:ok, invoice} = issue(ctx, draft)
    {:ok, before} = Invoicing.download(ctx.client, invoice.id)
    assert {:error, :already_issued} = issue(ctx, draft)

    assert {:error, :already_issued} =
             Invoicing.update_draft(ctx.client, invoice.id, ctx.actor, %{"notes" => "Changed"})

    assert {:ok, _} =
             Invoicing.save_profile(ctx.client, %{legal_name: "New name", address: "New address"})

    assert {:ok, _} =
             Invoicing.update_customer(ctx.client, ctx.customer.id, %{name: "New customer name"})

    assert {:ok, ^before} = Invoicing.download(ctx.client, invoice.id)
    assert {:ok, unchanged} = Invoicing.get_invoice(ctx.client, invoice.id)
    assert unchanged.snapshot["supplier"]["name"] == "Service Business"
    assert unchanged.snapshot["customer"]["name"] == "Unregistered Customer"
    {:ok, second} = draft(ctx)
    assert {:ok, %{number: "INV/2627/0002"}} = issue(ctx, second)
  end

  test "invoice date selects financial-year sequence and explicit POS selects tax heads", ctx do
    {:ok, previous} = draft(ctx, %{"invoice_date" => "2026-03-31", "place_of_supply" => "29"})
    assert {:ok, invoice} = issue(ctx, previous)
    assert invoice.number == "INV/2526/0001"
    assert invoice.totals["igst_paise"] == 18_000
    assert invoice.totals["cgst_paise"] == 0
    {:ok, current} = draft(ctx, %{"invoice_date" => "2026-04-01"})
    assert {:ok, %{number: "INV/2627/0001"}} = issue(ctx, current)
  end

  test "render failure rolls back numbering and leaves draft untouched", ctx do
    {:ok, draft} = draft(ctx)

    assert {:error, :renderer_down} =
             Invoicing.issue(ctx.client, draft.id, ctx.actor,
               render_pdf: fn _ -> {:error, :renderer_down} end
             )

    assert Repo.get!(Invoice, draft.id).status == "draft"

    assert {:error, :not_found} =
             Months.get_by_period(ctx.client.org_id, ctx.client.id, "2026-09")

    assert {:ok, %{number: "INV/2627/0001"}} = issue(ctx, draft)
  end

  test "filed month refuses issuance and reviewed month is reopened", ctx do
    {:ok, first} = draft(ctx)
    {:ok, _} = issue(ctx, first)
    {:ok, month} = Months.get_by_period(ctx.client.org_id, ctx.client.id, "2026-09")
    month |> change(state: "reviewed") |> Repo.update!()
    {:ok, next} = draft(ctx)
    {:ok, _} = issue(ctx, next)
    assert Repo.get!(Nila.Gst.Sales.Month, month.id).state == "worked"
    month |> change(filed_at: DateTime.utc_now()) |> Repo.update!()
    {:ok, blocked} = draft(ctx)
    assert {:error, :month_filed} = issue(ctx, blocked)
    assert Repo.get!(Invoice, blocked.id).status == "draft"
  end

  test "business scope prevents foreign customer and invoice access", ctx do
    {:ok, other} =
      Nila.Clients.create_client(%{
        org_id: ctx.client.org_id,
        name: "Other business",
        type: "company"
      })

    {:ok, invoice} = draft(ctx)
    assert {:error, :not_found} = Invoicing.get_invoice(other, invoice.id)
    assert {:error, :not_found} = Invoicing.issue(other, invoice.id, ctx.actor)

    assert {:error, :not_found} =
             Invoicing.save_draft(other, ctx.actor, %{"customer_id" => ctx.customer.id})
  end

  test "invalid and zero-valued service lines are refused", ctx do
    for {field, value} <- [
          {"quantity", "0"},
          {"quantity", "-1"},
          {"quantity", "NaN"},
          {"unit_price", "1.234"},
          {"sac", "123456"},
          {"gst_rate", "99"},
          {"gst_rate", "17"}
        ] do
      line = %{
        "description" => "Consulting",
        "sac" => "998312",
        "quantity" => "1",
        "unit_price" => "10",
        "gst_rate" => "18"
      }

      assert {:error, %Ecto.Changeset{}} = draft(ctx, %{"lines" => [Map.put(line, field, value)]})
    end
  end

  test "goods quote converts to an invoice with HSN, unit and tax in CA sales", ctx do
    goods = %{
      "description" => "Refrigerant gas",
      "kind" => "goods",
      "sac" => "290339",
      "unit" => "KGS",
      "quantity" => "2",
      "unit_price" => "500",
      "gst_rate" => "18"
    }

    {:ok, saved_item} =
      Invoicing.create_service(ctx.client, %{
        description: goods["description"],
        kind: "goods",
        sac: goods["sac"],
        unit: goods["unit"],
        unit_price: "500",
        gst_rate: "18"
      })

    assert saved_item.kind == "goods"
    {:ok, quote} = draft(ctx, %{"document_type" => "quotation", "lines" => [goods]})
    assert {:ok, quote} = issue(ctx, quote)
    assert hd(quote.snapshot["lines"])["kind"] == "goods"
    assert hd(quote.snapshot["lines"])["unit"] == "KGS"
    assert quote.dump_id == nil

    {:ok, _} = Invoicing.quotation_status(ctx.client, quote.id, ctx.actor, "accepted")

    assert {:ok, %{invoice: invoice}} =
             Invoicing.convert_quotation(ctx.client, quote.id, ctx.actor)

    assert hd(invoice.lines)["kind"] == "goods"
    assert {:ok, issued} = issue(ctx, invoice)
    assert issued.totals["total_paise"] == 118_000
    dump = Repo.get!(Nila.Gst.Intake.Dump, issued.dump_id)
    [line] = hd(dump.invoices)["line_items"]
    assert line["hsn_sac"] == "290339"
    assert line["uom"] == "KGS"

    {:ok, credit} =
      draft(ctx, %{
        "document_type" => "credit_note",
        "original_invoice_id" => issued.id,
        "invoice_date" => Date.to_iso8601(Date.utc_today()),
        "lines" => [Map.put(goods, "unit_price", "200")]
      })

    assert {:ok, _} = issue(ctx, credit)
  end

  test "business can continue quotation numbers, finalize in one transaction and revise without changing the sent PDF",
       ctx do
    assert {:ok, numbering} =
             Invoicing.configure_quotation_numbering(ctx.client, %{
               "next_quotation_number" => "GR-79"
             })

    assert numbering.next_number == 79
    assert numbering.style == "custom"
    assert numbering.next_quotation_number == "GR-79"

    {:ok, _} =
      Invoicing.save_profile(ctx.client, %{phone: "9962550448", email: "quotes@example.com"})

    attrs = %{
      "customer_id" => ctx.customer.id,
      "invoice_date" => "2026-09-24",
      "place_of_supply" => "33",
      "delivery_address" => "IndiraGandhi Hospital, Puducherry",
      "delivery_state_code" => "34",
      "subject" => "Compressor and Pipe Supply and Insulation",
      "lines" => [
        %{
          "kind" => "goods",
          "description" => "Compressor",
          "sac" => "84143000",
          "unit" => "NOS",
          "quantity" => "1",
          "unit_price" => "5200",
          "gst_rate" => "18"
        }
      ]
    }

    render = fn snapshot -> {:ok, "%PDF-test " <> snapshot["number"]} end

    assert {:error, %Ecto.Changeset{}} =
             Invoicing.finalize_quotation(ctx.client, ctx.actor, put_in(attrs["lines"], []), nil,
               render_pdf: render
             )

    assert Invoicing.list_invoices(ctx.client) == []
    assert Invoicing.quotation_numbering(ctx.client).next_number == 79

    assert {:ok, quote} =
             Invoicing.finalize_quotation(ctx.client, ctx.actor, attrs, nil, render_pdf: render)

    assert quote.number == "GR-79"
    assert quote.snapshot["subject"] == attrs["subject"]
    assert quote.snapshot["delivery_state_code"] == "34"
    assert quote.snapshot["supplier"]["phone"] == "9962550448"
    assert quote.snapshot["supplier"]["email"] == "quotes@example.com"
    assert quote.dump_id == nil
    assert {:ok, original_pdf} = Invoicing.download(ctx.client, quote.id)

    assert {:ok, reconfigured} =
             Invoicing.configure_quotation_numbering(ctx.client, %{
               "next_quotation_number" => "QTN/0156"
             })

    assert reconfigured.next_quotation_number == "QTN/0156"

    assert {:ok, revision} = Invoicing.revise_quotation(ctx.client, quote.id, ctx.actor)
    assert revision.status == "draft"
    assert revision.revised_from_id == quote.id
    assert revision.subject == attrs["subject"]
    assert revision.delivery_state_code == "34"
    assert {:ok, revised} = issue(ctx, revision)
    assert revised.number == "QTN/0156"
    assert revised.snapshot["revised_from_number"] == quote.number
    assert {:ok, ^original_pdf} = Invoicing.download(ctx.client, quote.id)
  end

  test "custom quotation numbers continue across financial years", ctx do
    {:ok, numbering} =
      Invoicing.configure_quotation_numbering(ctx.client, %{"next_quotation_number" => "GR-50"})

    year = numbering.financial_year

    Repo.query!(
      "DELETE FROM business_invoice_counters WHERE client_id = $1 AND financial_year = $2 AND document_type = 'quotation'",
      [ctx.client.id, year]
    )

    Repo.query!(
      "INSERT INTO business_invoice_counters (client_id, financial_year, document_type, last_number) VALUES ($1, $2, 'quotation', 50)",
      [ctx.client.id, year - 1]
    )

    assert Invoicing.quotation_numbering(ctx.client).next_quotation_number == "GR-51"

    {:ok, draft} =
      draft(ctx, %{
        "document_type" => "quotation",
        "invoice_date" => Date.to_iso8601(Date.utc_today())
      })

    assert {:ok, %{number: "GR-51"}} = issue(ctx, draft)
  end

  test "quotation finalization rejects an invoice draft without changing it", ctx do
    {:ok, invoice} = draft(ctx)

    assert {:error, :invalid_document_type} =
             Invoicing.finalize_quotation(
               ctx.client,
               ctx.actor,
               %{"subject" => "Should not be saved"},
               invoice.id
             )

    unchanged = Nila.Repo.get!(Nila.Business.Invoice, invoice.id)
    assert unchanged.document_type == "invoice"
    assert unchanged.status == "draft"
    assert unchanged.subject == nil
  end

  test "business branding accepts scoped PNG or JPEG files and can be removed", ctx do
    png = File.read!("priv/static/images/og-image.png")
    assert {:error, :invalid_asset} = Invoicing.save_brand_asset(ctx.client, "logo", "<svg/>")

    assert {:error, :invalid_asset} =
             Invoicing.save_brand_asset(ctx.client, "logo", binary_part(png, 0, 32))

    assert {:error, :invalid_asset} =
             Invoicing.save_brand_asset(ctx.client, "logo", :binary.copy(png, 20))

    assert {:ok, profile} = Invoicing.save_brand_asset(ctx.client, "logo", png)
    assert profile.logo_key
    assert {:ok, ^png, "image/png"} = Invoicing.get_brand_asset(ctx.client, "logo")

    assert {:error, :not_found} =
             Invoicing.get_brand_asset(%{ctx.client | id: -1}, "logo")

    assert {:ok, removed} = Invoicing.remove_brand_asset(ctx.client, "logo")
    assert removed.logo_key == nil
    assert {:error, :not_found} = Invoicing.get_brand_asset(ctx.client, "logo")
  end

  test "goods lines require a valid HSN and goods unit", ctx do
    base = %{
      "description" => "Refrigerant gas",
      "kind" => "goods",
      "sac" => "290339",
      "unit" => "KGS",
      "quantity" => "1",
      "unit_price" => "500",
      "gst_rate" => "18"
    }

    for {field, value} <- [
          {"sac", "998313"},
          {"sac", "2903"},
          {"sac", "12345"},
          {"unit", "hour"},
          {"kind", "stock"}
        ] do
      assert {:error, %Ecto.Changeset{}} = draft(ctx, %{"lines" => [Map.put(base, field, value)]})
    end

    assert {:ok, _} = draft(ctx, %{"lines" => [Map.put(base, "sac", "29033990")]})
  end

  test "credit notes reduce CA totals and cannot cumulatively overcredit the original", ctx do
    {:ok, original} = draft(ctx)
    {:ok, original} = issue(ctx, original)

    credit_attrs = %{
      "document_type" => "credit_note",
      "original_invoice_id" => original.id,
      "lines" => [
        %{
          "description" => "Partial credit",
          "sac" => "998312",
          "quantity" => "1",
          "unit_price" => "600",
          "gst_rate" => "18"
        }
      ]
    }

    {:ok, credit} = draft(ctx, credit_attrs)
    assert {:ok, credit} = issue(ctx, credit)
    assert credit.number == "CN/2627/0001"
    assert credit.snapshot["original_invoice_number"] == original.number
    assert credit.snapshot["original_invoice_date"] == "2026-09-22"
    {:ok, month} = Months.get_by_period(ctx.client.org_id, ctx.client.id, "2026-09")
    assert Enum.any?(month.invoices, &(&1["document_type"] == "credit_note"))
    {:ok, excess} = draft(ctx, credit_attrs)
    assert {:error, :credit_exceeds_original} = issue(ctx, excess)
  end

  test "unregistered interstate large invoice credit preserves original category", ctx do
    {:ok, original} =
      draft(ctx, %{
        "place_of_supply" => "29",
        "lines" => [
          %{
            "description" => "Consulting",
            "sac" => "998312",
            "quantity" => "1",
            "unit_price" => "100000",
            "gst_rate" => "18"
          }
        ]
      })

    {:ok, original} = issue(ctx, original)

    {:ok, credit} =
      draft(ctx, %{
        "document_type" => "credit_note",
        "original_invoice_id" => original.id,
        "place_of_supply" => "29"
      })

    {:ok, credit} = issue(ctx, credit)
    assert credit.snapshot["original_sale_category"] == "b2cl"
    dump = Repo.get!(Nila.Gst.Intake.Dump, credit.dump_id)
    assert hd(dump.invoices)["original_sale_category"] == "b2cl"
  end

  test "quotation finalization and conversion have no sales effect until invoice issue", ctx do
    attrs = %{
      "document_type" => "quotation",
      "valid_until" => "2026-10-01",
      "purchase_order_number" => "RFQ-23",
      "purchase_order_date" => "2026-09-01",
      "delivery_address" => "Site office",
      "notes" => "Payment on completion"
    }

    {:ok, quote} = draft(ctx, attrs)
    assert {:ok, quote} = issue(ctx, quote)
    assert quote.number == "QT/2627/0001"
    assert quote.snapshot["document_type"] == "quotation"
    assert quote.snapshot["valid_until"] == "2026-10-01"
    assert quote.dump_id == nil
    assert {:ok, pdf} = Invoicing.download(ctx.client, quote.id)

    assert {:error, :quotation_not_accepted} =
             Invoicing.convert_quotation(ctx.client, quote.id, ctx.actor)

    assert {:ok, _} = Invoicing.quotation_status(ctx.client, quote.id, ctx.actor, "declined")
    assert {:ok, _} = Invoicing.quotation_status(ctx.client, quote.id, ctx.actor, "accepted")
    assert {:ok, _} = Invoicing.quotation_status(ctx.client, quote.id, ctx.actor, "accepted")

    assert {:ok, %{invoice: invoice, quotation: converted}} =
             Invoicing.convert_quotation(ctx.client, quote.id, ctx.actor)

    assert converted.status == "converted"
    assert converted.converted_invoice_id == invoice.id
    assert invoice.document_type == "invoice"
    assert invoice.status == "draft"
    assert invoice.invoice_date == Date.utc_today()
    assert invoice.valid_until == nil
    assert invoice.due_date == nil
    assert invoice.number == nil
    assert quote.purchase_order_number == "RFQ-23"
    assert invoice.purchase_order_number == nil
    assert invoice.purchase_order_date == nil

    for field <- [
          :customer_id,
          :place_of_supply,
          :lines,
          :notes,
          :delivery_address
        ] do
      assert Map.get(invoice, field) == Map.get(quote, field)
    end

    assert {:ok, %{invoice: retry}} = Invoicing.convert_quotation(ctx.client, quote.id, ctx.actor)
    assert retry.id == invoice.id
    assert {:ok, ^pdf} = Invoicing.download(ctx.client, quote.id)

    assert {:error, :invalid_quotation_status} =
             Invoicing.quotation_status(ctx.client, quote.id, ctx.actor, "declined")

    assert {:error, :already_issued} =
             Invoicing.update_draft(ctx.client, quote.id, ctx.actor, %{"notes" => "changed"})

    assert Repo.aggregate(
             from(d in Nila.Gst.Intake.Dump, where: d.client_id == ^ctx.client.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(m in Nila.Gst.Sales.Month, where: m.client_id == ^ctx.client.id),
             :count
           ) == 0

    assert {:ok, issued} = issue(ctx, invoice)
    assert String.starts_with?(issued.number, "INV/")
    assert String.ends_with?(issued.number, "/0001")

    assert Repo.aggregate(
             from(d in Nila.Gst.Intake.Dump, where: d.client_id == ^ctx.client.id),
             :count
           ) == 1

    assert Repo.aggregate(
             from(m in Nila.Gst.Sales.Month, where: m.client_id == ^ctx.client.id),
             :count
           ) == 1
  end

  test "quotation expiry, tenant and transition guards preserve document identity", ctx do
    assert {:error, changeset} =
             draft(ctx, %{"document_type" => "quotation", "valid_until" => "2026-09-21"})

    assert errors_on(changeset).valid_until == ["cannot precede the quotation date"]
    {:ok, quote} = draft(ctx, %{"document_type" => "quotation"})

    assert {:error, :invalid_quotation_status} =
             Invoicing.quotation_status(ctx.client, quote.id, ctx.actor, "accepted")

    assert {:error, :quotation_not_accepted} =
             Invoicing.convert_quotation(ctx.client, quote.id, ctx.actor)

    assert {:ok, unchanged} =
             Invoicing.update_draft(ctx.client, quote.id, ctx.actor, %{
               "document_type" => "invoice",
               "status" => "accepted",
               "converted_invoice_id" => quote.id
             })

    assert unchanged.document_type == "quotation"
    assert unchanged.status == "draft"
    assert unchanged.converted_invoice_id == nil
    other = %{ctx.client | id: -1}

    assert {:error, :not_found} =
             Invoicing.quotation_status(other, quote.id, ctx.actor, "accepted")

    assert {:error, :not_found} = Invoicing.convert_quotation(other, quote.id, ctx.actor)
    {:ok, invoice} = draft(ctx)

    assert {:error, :invalid_quotation_status} =
             Invoicing.quotation_status(ctx.client, invoice.id, ctx.actor, "accepted")
  end

  test "quotation bypasses filed sales month", ctx do
    {:ok, invoice} = draft(ctx)
    {:ok, _} = issue(ctx, invoice)
    {:ok, month} = Months.get_by_period(ctx.client.org_id, ctx.client.id, "2026-09")
    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()

    {:ok, quote} = draft(ctx, %{"document_type" => "quotation"})
    assert {:ok, quote} = issue(ctx, quote)
    assert quote.dump_id == nil

    assert Repo.aggregate(
             from(d in Nila.Gst.Intake.Dump, where: d.client_id == ^ctx.client.id),
             :count
           ) == 1

    assert Repo.get!(Nila.Gst.Sales.Month, month.id).invoices == month.invoices
  end

  test "quotation can use complete client details without creating a business profile", ctx do
    Repo.delete!(Invoicing.get_profile(ctx.client))

    client =
      ctx.client |> Ecto.Changeset.change(address: "Client office, Chennai") |> Repo.update!()

    ctx = %{ctx | client: client}
    {:ok, quote} = draft(ctx, %{"document_type" => "quotation"})
    assert {:ok, quote} = issue(ctx, quote)
    assert quote.snapshot["supplier"]["address"] == client.address
    assert quote.snapshot["supplier"]["name"] == client.name
    assert Invoicing.get_profile(client).id == nil
    {:ok, invoice} = draft(ctx)
    assert {:error, :profile_incomplete} = issue(ctx, invoice)
    client = client |> Ecto.Changeset.change(address: nil) |> Repo.update!()
    ctx = %{ctx | client: client}
    {:ok, incomplete} = draft(ctx, %{"document_type" => "quotation"})
    assert {:error, :profile_incomplete} = issue(ctx, incomplete)
  end

  test "service catalogue is tenant scoped and changes never rewrite copied invoice lines", ctx do
    attrs = %{
      description: "Consulting hour",
      sac: "998312",
      unit: "hour",
      unit_price: "500.25",
      gst_rate: "18",
      client_id: -1
    }

    assert {:ok, service} = Invoicing.create_service(ctx.client, attrs)
    assert service.client_id == ctx.client.id
    assert [listed] = Invoicing.list_services(ctx.client)
    assert listed.id == service.id
    other = %{ctx.client | id: -1}
    assert Invoicing.list_services(other) == []
    assert {:error, :not_found} = Invoicing.update_service(other, service.id, %{unit_price: "1"})
    assert {:error, :not_found} = Invoicing.delete_service(other, service.id)

    line =
      attrs
      |> Map.drop([:client_id])
      |> Map.put(:quantity, "2")
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    {:ok, invoice} = draft(ctx, %{"lines" => [line]})

    assert {:ok, _} =
             Invoicing.update_service(ctx.client, service.id, %{
               description: "Changed",
               unit_price: "900"
             })

    assert {:ok, _} = Invoicing.delete_service(ctx.client, service.id)
    assert {:ok, saved} = Invoicing.get_invoice(ctx.client, invoice.id)
    assert saved.lines == [line]
    assert {:ok, issued} = issue(ctx, saved)
    assert hd(issued.snapshot["lines"])["unit"] == "hour"
    assert hd(issued.snapshot["lines"])["unit_price"] == "500.25"
    assert Invoicing.list_services(ctx.client) == []
  end

  test "service catalogue rejects unsupported rates and amounts before persistence", ctx do
    attrs = %{description: "Consulting", sac: "998312", unit_price: "100", gst_rate: "18"}

    for {field, value} <- [
          description: "",
          sac: "123456",
          unit_price: "0",
          unit_price: "1.234",
          gst_rate: "17",
          unit: String.duplicate("x", 31)
        ] do
      assert {:error, changeset} =
               Invoicing.create_service(ctx.client, Map.put(attrs, field, value))

      assert Map.has_key?(errors_on(changeset), field)
    end

    assert {:ok, service} = Invoicing.create_service(ctx.client, attrs)
    assert service.unit == "service"
  end
end
