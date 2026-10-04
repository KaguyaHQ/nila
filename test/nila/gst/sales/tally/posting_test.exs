defmodule Nila.Gst.Sales.Tally.PostingTest do
  use Nila.DataCase, async: true
  import Nila.AccountsFixtures
  alias Nila.{Clients, Repo, TallyDevices, TallyMappings, TallyJobs}
  alias Nila.Gst.Sales.{Batch, Months}
  alias Nila.Gst.Sales.Tally.Posting
  alias Nila.TallyDevices.SyncedMaster

  setup do
    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, device, _} = TallyDevices.create_device(org, %{name: "Accounts"})

    {:ok, [company]} =
      TallyDevices.report_companies(device, [
        %{
          "name" => "Breeze",
          "guid" => Ecto.UUID.generate(),
          "gstin" => client.gstin,
          "is_open" => true
        }
      ])

    client =
      client |> Ecto.Changeset.change(active_tally_company_id: company.id) |> Repo.update!()

    Repo.insert!(%Nila.TallyDevices.SyncRun{
      org_id: org.id,
      device_id: device.id,
      company_id: company.id,
      status: "succeeded",
      masters_status: "succeeded",
      vouchers_status: "succeeded",
      period_start: ~D[2026-08-01],
      period_end: ~D[2026-08-31],
      started_at: DateTime.utc_now(),
      completed_at: DateTime.utc_now()
    })

    {:ok, batch} = Batch.create(org.id, client.id, "august")

    invoice = %{
      "id" => "d1_inv1",
      "invoice_number" => "73",
      "invoice_date" => "2026-08-25",
      "seller_gstin" => client.gstin,
      "buyer_name" => "Philips",
      "buyer_gstin" => "33AABCP9487A1ZG",
      "place_of_supply" => "33",
      "recipient_registration" => "registered",
      "line_items" => [line("Labour", 1000, 18), line("Materials", 500, 18)]
    }

    Repo.insert!(%Nila.Gst.Intake.Dump{
      org_id: org.id,
      client_id: client.id,
      period: "2026-08",
      kind: "sales",
      status: "extracted",
      sales_batch_id: batch.id,
      invoices: [invoice]
    })

    {:ok, _} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-08",
        invoices: [invoice]
      })

    for {identity, name, data} <- [
          {"party", "Philips",
           %{"parent" => "Sundry Debtors", "gstin" => invoice["buyer_gstin"]}},
          {"sales18", "Labour @ 18%", %{"parent" => "Sales Accounts"}},
          {"sales5", "Materials @ 18%", %{"parent" => "Sales Accounts"}},
          {"cgst", "Output CGST",
           %{
             "parent" => "Duties & Taxes",
             "gst_duty_head" => "CGST",
             "tax_type" => "GST",
             "rate_of_tax" => 9
           }},
          {"sgst", "Output SGST",
           %{
             "parent" => "Duties & Taxes",
             "gst_duty_head" => "SGST",
             "tax_type" => "GST",
             "rate_of_tax" => 9
           }}
        ] do
      Repo.insert!(%SyncedMaster{
        org_id: org.id,
        company_id: company.id,
        kind: "ledger",
        identity: identity,
        name: name,
        data: data
      })
    end

    Repo.insert!(%SyncedMaster{
      org_id: org.id,
      company_id: company.id,
      kind: "voucher_type",
      identity: "sales-type",
      name: "Sales",
      data: %{"numbering_method" => "Manual"}
    })

    for {line, ledger} <- Enum.zip(invoice["line_items"], ["sales18", "sales5"]),
        do: TallyMappings.save_sales_ledger_choice(org.id, company.id, line, ledger)

    {:ok, _} =
      TallyMappings.save_posting_profile(org.id, company.id, %{
        cgst_ledger_identity: "cgst",
        sgst_ledger_identity: "sgst"
      })

    %{org: org, client: client, company: company, batch: batch}
  end

  test "previews every sales allocation and the exact amounts used by XML", c do
    assert {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")
    [row] = data.proposals

    assert Enum.map(row.sales_entries, &{&1.ledger_name, &1.amount}) == [
             {"Labour @ 18%", "1000.00"},
             {"Materials @ 18%", "500.00"}
           ]

    assert row.grand_total == "1770.00"
    assert Enum.map(row.tax_entries, & &1.amount) == ["135.00", "135.00"]
    assert row.status == "ready", inspect(row.issues)
    assert {:ok, again} = Posting.load(c.org.id, c.client, "2026-08")
    assert again.preview_token == data.preview_token
  end

  test "changed mappings invalidate the posting preview without creating a job", c do
    {:ok, before} = Posting.load(c.org.id, c.client, "2026-08")

    assert {:ok, :saved} =
             Posting.update(c.org.id, c.client, "2026-08", "d1_inv1", %{
               "preview_token" => before.preview_token,
               "line_sales_ledger_identities" => %{"1" => "sales18"}
             })

    assert {:error, :stale_or_not_ready} =
             Posting.post(c.org.id, c.client, "2026-08", %{
               "company_id" => c.company.id,
               "invoice_ids" => ["d1_inv1"],
               "preview_token" => before.preview_token
             })

    assert TallyJobs.list_by_sales_batch(c.org.id, c.batch.id) == []
  end

  test "panel summaries combine only the same chosen ledger and retain source line IDs", c do
    {:ok, before} = Posting.load(c.org.id, c.client, "2026-08")
    [proposal] = Posting.project(before).proposals
    assert Enum.map(proposal.sales_summary, & &1.line_ids) == [["0"], ["1"]]

    assert {:ok, :saved} =
             Posting.update(c.org.id, c.client, "2026-08", "d1_inv1", %{
               "preview_token" => before.preview_token,
               "line_sales_ledger_identities" => %{"1" => "sales18"}
             })

    {:ok, after_save} = Posting.load(c.org.id, c.client, "2026-08")
    [proposal] = Posting.project(after_save).proposals

    assert [%{ledger_identity: "sales18", amount: "1500.00", line_ids: ["0", "1"]}] =
             proposal.sales_summary

    assert length(proposal.sales_entries) == 2
  end

  test "source corrections and ledger choices save together and rebuild the proposal", c do
    {:ok, before} = Posting.load(c.org.id, c.client, "2026-08")

    attrs = %{
      "preview_token" => before.preview_token,
      "source_changes" => %{
        "line_items[0].taxable_value" => "2000",
        "line_items[0].cgst_amount" => "180",
        "line_items[0].sgst_amount" => "180"
      },
      "line_sales_ledger_identities" => %{"0" => "sales5"}
    }

    assert {:ok, :saved} = Posting.update(c.org.id, c.client, "2026-08", "d1_inv1", attrs)
    {:ok, after_save} = Posting.load(c.org.id, c.client, "2026-08")
    [row] = after_save.proposals
    assert hd(row.sales_entries).amount == "2000.00"
    assert hd(row.sales_entries).ledger_name == "Materials @ 18%"
    assert row.grand_total == "2950.00"
    assert Enum.map(row.tax_entries, & &1.amount) == ["225.00", "225.00"]
    assert after_save.preview_token != before.preview_token
    assert length(Nila.Gst.Sales.Invoice.Corrections.list(c.org.id, c.client.id, "d1_inv1")) == 3
    assert TallyJobs.list_by_sales_batch(c.org.id, c.batch.id) == []
    assert {:error, _} = Posting.update(c.org.id, c.client, "2026-08", "d1_inv1", attrs)
  end

  test "an invalid ledger rolls back source corrections too", c do
    {:ok, before} = Posting.load(c.org.id, c.client, "2026-08")

    assert {:error, _} =
             Posting.update(c.org.id, c.client, "2026-08", "d1_inv1", %{
               "preview_token" => before.preview_token,
               "source_changes" => %{"line_items[0].taxable_value" => "2000"},
               "line_sales_ledger_identities" => %{"0" => "missing-ledger"}
             })

    assert Nila.Gst.Sales.Invoice.Corrections.list(c.org.id, c.client.id, "d1_inv1") == []
    {:ok, after_save} = Posting.load(c.org.id, c.client, "2026-08")
    assert after_save.preview_token == before.preview_token
  end

  test "posting creates one durable job and a repeated request cannot create another", c do
    {:ok, before} = Posting.load(c.org.id, c.client, "2026-08")

    attrs = %{
      "company_id" => c.company.id,
      "invoice_ids" => ["d1_inv1"],
      "preview_token" => before.preview_token
    }

    assert {:ok, 1} = Posting.post(c.org.id, c.client, "2026-08", attrs)
    assert {:error, :stale_or_not_ready} = Posting.post(c.org.id, c.client, "2026-08", attrs)
    [job] = TallyJobs.list_by_sales_batch(c.org.id, c.batch.id)
    assert job.status == "pending"
    assert job.payload["xml"] =~ "Labour @ 18%"
    assert job.payload["xml"] =~ "Materials @ 18%"
    assert job.payload["xml"] =~ "<AMOUNT>135.00</AMOUNT>"
    {:ok, after_post} = Posting.load(c.org.id, c.client, "2026-08")
    assert hd(after_post.proposals).status == "pending"
  end

  test "a queued voucher keeps its original preview and source identity after later changes", c do
    {:ok, before} = Posting.load(c.org.id, c.client, "2026-08")

    assert {:ok, 1} =
             Posting.post(c.org.id, c.client, "2026-08", %{
               "company_id" => c.company.id,
               "invoice_ids" => ["d1_inv1"],
               "preview_token" => before.preview_token
             })

    {:ok, month} = Months.get_by_period(c.org.id, c.client.id, "2026-08")
    [invoice] = month.invoices

    TallyMappings.save_sales_ledger_choice(
      c.org.id,
      c.company.id,
      hd(invoice["line_items"]),
      "sales5"
    )

    invoice =
      invoice
      |> Map.put("invoice_number", "changed-number")
      |> Map.put("invoice_date", "2026-08-26")

    {:ok, _} =
      Months.upsert(%{
        org_id: c.org.id,
        client_id: c.client.id,
        period: "2026-08",
        invoices: [invoice]
      })

    dump = Repo.get_by!(Nila.Gst.Intake.Dump, sales_batch_id: c.batch.id)
    dump |> Ecto.Changeset.change(invoices: [invoice]) |> Repo.update!()
    {:ok, after_change} = Posting.load(c.org.id, c.client, "2026-08")
    [row] = after_change.proposals
    assert row.status == "pending"
    assert row.number == "73"
    assert row.date == "2026-08-25"
    assert hd(row.sales_entries).ledger_name == "Labour @ 18%"
    assert after_change.ready_count == 0
    assert length(TallyJobs.list_by_sales_batch(c.org.id, c.batch.id)) == 1
  end

  test "an existing Tally invoice number prevents duplicate creation", c do
    Repo.insert!(%Nila.TallyDevices.SyncedVoucher{
      org_id: c.org.id,
      company_id: c.company.id,
      identity: "existing",
      voucher_type: "Sales",
      voucher_number: "73",
      date: ~D[2026-08-25]
    })

    {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")
    [row] = data.proposals
    assert row.status == "needs_input"
    assert Enum.any?(row.issues, &String.contains?(&1, "already exists"))
  end

  test "multiple existing vouchers become one counted warning on the source invoice", c do
    for identity <- ["existing-1", "existing-2"] do
      Repo.insert!(%Nila.TallyDevices.SyncedVoucher{
        org_id: c.org.id,
        company_id: c.company.id,
        identity: identity,
        voucher_type: "Sales",
        voucher_number: "73",
        date: ~D[2026-08-25]
      })
    end

    {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")
    assert [row] = data.proposals
    assert row.status == "needs_input"
    assert data.ready_count == 0

    assert row.issues == [
             "2 entries with this invoice number and date already exist in Tally. Check them before posting."
           ]
  end

  test "summarized Tally lines never replace the bill's posting facts or checks", c do
    Repo.insert!(%Nila.TallyDevices.SyncedVoucher{
      org_id: c.org.id,
      company_id: c.company.id,
      identity: "summary",
      voucher_type: "Sales",
      voucher_number: "73",
      date: ~D[2026-08-25],
      data: %{
        "party_ledger_name" => "Philips",
        "party_gstin" => "33AABCP9487A1ZG",
        "place_of_supply" => "33",
        "line_items" => [
          %{
            "description" => "Tally sales",
            "taxable_value" => 1500,
            "cgst_amount" => 102.5,
            "sgst_amount" => 102.5
          }
        ]
      }
    })

    {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")
    [row] = data.proposals
    assert length(row.sales_entries) == 2
    assert Enum.map(row.sales_entries, & &1.amount) == ["1000.00", "500.00"]

    assert row.issues == [
             "An invoice with this number already exists in the latest Tally snapshot. Check it before creating another."
           ]
  end

  test "a previous year's same invoice number does not block the new invoice", c do
    Repo.insert!(%Nila.TallyDevices.SyncedVoucher{
      org_id: c.org.id,
      company_id: c.company.id,
      identity: "prior-year",
      voucher_type: "Sales",
      voucher_number: "73",
      date: ~D[2025-08-25]
    })

    {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")
    assert hd(data.proposals).status == "ready"
  end

  test "another month's snapshot cannot establish August invoices are absent", c do
    import Ecto.Query

    Repo.update_all(
      from(run in Nila.TallyDevices.SyncRun, where: run.company_id == ^c.company.id),
      set: [period_start: ~D[2026-10-01], period_end: ~D[2026-10-31]]
    )

    {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")
    assert hd(data.proposals).status == "needs_input"

    assert Enum.any?(
             hd(data.proposals).issues,
             &String.contains?(&1, "Sync vouchers for this month")
           )
  end

  test "unknown results explicitly queue read-only verification", c do
    {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")

    {:ok, 1} =
      Posting.post(c.org.id, c.client, "2026-08", %{
        "company_id" => c.company.id,
        "invoice_ids" => ["d1_inv1"],
        "preview_token" => data.preview_token
      })

    [job] = TallyJobs.list_by_sales_batch(c.org.id, c.batch.id)

    job
    |> Ecto.Changeset.change(
      status: "indeterminate",
      error: %{"message" => "Connection lost after sending"}
    )
    |> Repo.update!()

    assert {:ok, 1} = Posting.verify(c.org.id, c.client, "2026-08")
    [verified] = TallyJobs.list_by_sales_batch(c.org.id, c.batch.id)
    assert verified.payload["mode"] == "verify_only"
    assert verified.payload["xml"] == job.payload["xml"]
    assert verified.status == "pending"
  end

  test "old mappings without rates require reconfirmation instead of a profile fallback", c do
    import Ecto.Query

    Repo.delete_all(
      from m in Nila.TallyMappings.SalesLineMapping, where: m.company_id == ^c.company.id
    )

    digest = :crypto.hash(:sha256, "labour") |> Base.url_encode64(padding: false)

    Repo.insert!(%Nila.TallyMappings.SalesLineMapping{
      org_id: c.org.id,
      company_id: c.company.id,
      source_key: "hsn:998719:description:#{digest}",
      hsn_sac: "998719",
      normalized_description: "labour",
      ledger_identity: "sales5",
      confirmed_at: DateTime.utc_now()
    })

    {:ok, _} =
      TallyMappings.save_posting_profile(c.org.id, c.company.id, %{
        "sales_ledger_identity" => "sales18"
      })

    {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")
    assert hd(data.proposals).status == "needs_input"
    assert is_nil(hd(hd(data.proposals).sales_entries).ledger_name)
  end

  test "mixed tax rates are blocked even when a tax profile is already saved", c do
    replace_lines(c, [line("Labour", 1000, 18), line("Materials", 500, 5)])
    {:ok, data} = Posting.load(c.org.id, c.client, "2026-08")
    assert hd(data.proposals).status == "needs_input"
    assert Enum.any?(hd(data.proposals).issues, &String.contains?(&1, "multiple tax rates"))
    assert Enum.all?(hd(data.proposals).tax_entries, &is_nil(&1.ledger_identity))
  end

  test "identical descriptions at different rates retain separate explicit sales choices", c do
    a = line("Same description", 1000, 18)
    b = line("Same description", 500, 5)
    assert {:ok, _} = TallyMappings.save_sales_ledger_choice(c.org.id, c.company.id, a, "sales18")
    assert {:ok, _} = TallyMappings.save_sales_ledger_choice(c.org.id, c.company.id, b, "sales5")

    assert {:ok, %{ledger: %{identity: "sales18"}}} =
             TallyMappings.resolve_sales_ledger(c.org.id, c.company.id, a)

    assert {:ok, %{ledger: %{identity: "sales5"}}} =
             TallyMappings.resolve_sales_ledger(c.org.id, c.company.id, b)
  end

  test "stale mapping confirmation and wrong-rate tax selections are rejected", c do
    {:ok, before} = Posting.load(c.org.id, c.client, "2026-08")
    replace_lines(c, [line("Changed service", 1000, 18)])

    assert {:error, :invalid_mapping} =
             Posting.update(c.org.id, c.client, "2026-08", "d1_inv1", %{
               "preview_token" => before.preview_token,
               "line_sales_ledger_identities" => %{"0" => "sales18"}
             })

    tax = Repo.get_by!(SyncedMaster, company_id: c.company.id, identity: "cgst")
    tax |> Ecto.Changeset.change(data: Map.put(tax.data, "rate_of_tax", 2.5)) |> Repo.update!()
    {:ok, current} = Posting.load(c.org.id, c.client, "2026-08")

    assert {:error, :tax_rate_mismatch} =
             Posting.update(c.org.id, c.client, "2026-08", "d1_inv1", %{
               "preview_token" => current.preview_token,
               "tax_ledger_identities" => %{"cgst" => "cgst"}
             })
  end

  test "a first-use master suggestion becomes ready only after explicit confirmation", c do
    import Ecto.Query

    Repo.delete_all(
      from mapping in Nila.TallyMappings.SalesLineMapping,
        where: mapping.company_id == ^c.company.id
    )

    replace_lines(c, [line("New service", 1000, 18)])
    ledger = Repo.get_by!(SyncedMaster, company_id: c.company.id, identity: "sales18")

    ledger
    |> Ecto.Changeset.change(
      data:
        Map.merge(ledger.data, %{
          "hsn_details" => [
            %{
              "source" => "Specify Details Here",
              "hsnCode" => "998719",
              "applicableFrom" => "2020-01-01"
            }
          ],
          "gst_details" => [
            %{
              "sourceOfGSTDetails" => "Specify Details Here",
              "applicableFrom" => "2020-01-01",
              "stateWiseDetails" => [
                %{
                  "stateName" => "Any",
                  "gstRateDetails" => [
                    %{"dutyHead" => "CGST", "gstRate" => 9},
                    %{"dutyHead" => "SGST/UTGST", "gstRate" => 9}
                  ]
                }
              ]
            }
          ]
        })
    )
    |> Repo.update!()

    {:ok, before} = Posting.load(c.org.id, c.client, "2026-08")
    assert hd(before.proposals).status == "needs_input"
    assert hd(hd(before.proposals).sales_entries).suggested_ledger_identity == "sales18"
    assert is_nil(hd(hd(before.proposals).sales_entries).ledger_identity)

    assert {:ok, :saved} =
             Posting.update(c.org.id, c.client, "2026-08", "d1_inv1", %{
               "preview_token" => before.preview_token,
               "line_sales_ledger_identities" => %{"0" => "sales18"}
             })

    {:ok, after_confirmation} = Posting.load(c.org.id, c.client, "2026-08")
    assert hd(after_confirmation.proposals).status == "ready"
    assert hd(hd(after_confirmation.proposals).sales_entries).basis == "Saved ledger choice."
  end

  defp replace_lines(c, lines) do
    dump = Repo.get_by!(Nila.Gst.Intake.Dump, sales_batch_id: c.batch.id)
    [invoice] = dump.invoices
    invoice = Map.put(invoice, "line_items", lines)
    dump |> Ecto.Changeset.change(invoices: [invoice]) |> Repo.update!()
    {:ok, month} = Months.get_by_period(c.org.id, c.client.id, "2026-08")
    month |> Ecto.Changeset.change(invoices: [invoice]) |> Repo.update!()
  end

  defp line(description, value, rate),
    do: %{
      "item_name" => description,
      "description" => description <> " for August service contract",
      "hsn_sac" => "998719",
      "taxable_value" => value,
      "printed_taxable_value" => value,
      "cgst_rate" => rate / 2,
      "sgst_rate" => rate / 2,
      "cgst_amount" => value * rate / 200,
      "sgst_amount" => value * rate / 200
    }
end
