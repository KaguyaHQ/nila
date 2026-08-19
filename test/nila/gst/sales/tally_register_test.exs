defmodule Nila.Gst.Sales.TallyRegisterTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Sales.{Months, TallyRegister}
  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.{SyncRun, SyncedVoucher}

  @period "2026-08"

  setup do
    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "ABC Traders",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "Accounts PC"})
    {:ok, [company]} = TallyDevices.report_companies(device, [%{"name" => "ABC Traders"}])
    company = company |> Ecto.Changeset.change(client_id: client.id) |> Repo.update!()

    Repo.insert!(%SyncRun{
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

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        invoices: [document("DOC-1", "INV-1"), document("DOC-2", "INV-2")]
      })

    %{org: org, client: client, company: company, month: month}
  end

  test "matches books to evidence and surfaces both missing sides and disagreements", context do
    tally_voucher!(context, "v-1", "INV-1", "29AABCP9487A1ZG", 100.0)
    tally_voucher!(context, "v-3", "INV-3", nil, 300.0)

    projection = TallyRegister.project(context.month)

    assert Enum.map(projection.invoices, & &1["invoice_number"]) == ["INV-1", "INV-2", "INV-3"]

    matched = Enum.find(projection.invoices, &(&1["invoice_number"] == "INV-1"))
    assert matched["id"] == "DOC-1"
    assert matched["sources"] == ["tally", "document"]
    assert matched["buyer_name"] == "Tally Customer"

    assert Enum.sort(Enum.map(projection.issues, & &1["code"])) ==
             Enum.sort(~w(sales_document_missing sales_not_in_tally tally_document_mismatch))

    assert projection.summary.matched == 1
    assert projection.summary.missing_document == 1
    assert projection.summary.missing_tally == 1
    assert projection.summary.conflicts == 1
  end

  test "reads alterations and deletions from the latest snapshot without duplicating rows",
       context do
    voucher = tally_voucher!(context, "v-1", "INV-1", "33AABCP9487A1ZG", 100.0)

    first = TallyRegister.project(context.month)
    assert totals(first, "INV-1") == 100.0

    voucher
    |> Ecto.Changeset.change(data: voucher_data("33AABCP9487A1ZG", 250.0))
    |> Repo.update!()

    altered = TallyRegister.project(context.month)
    assert totals(altered, "INV-1") == 250.0
    assert Enum.count(altered.invoices, &(&1["invoice_number"] == "INV-1")) == 1

    Repo.delete!(voucher)

    deleted = TallyRegister.project(context.month)

    assert Enum.find(deleted.invoices, &(&1["invoice_number"] == "INV-1"))["sources"] == [
             "document"
           ]

    assert Enum.any?(deleted.issues, &(&1["code"] == "sales_not_in_tally"))
  end

  defp document(id, number) do
    %{
      "id" => id,
      "document_type" => "invoice",
      "invoice_number" => number,
      "invoice_date" => ~D[2026-08-19],
      "buyer_name" => "Document Customer",
      "buyer_gstin" => "33AABCP9487A1ZG",
      "place_of_supply" => "33",
      "line_items" => [line(100.0)]
    }
  end

  defp tally_voucher!(context, identity, number, gstin, taxable) do
    Repo.insert!(%SyncedVoucher{
      org_id: context.org.id,
      company_id: context.company.id,
      identity: identity,
      date: ~D[2026-08-19],
      voucher_type: "Sales",
      voucher_number: number,
      data: voucher_data(gstin, taxable)
    })
  end

  defp voucher_data(gstin, taxable) do
    %{
      "party_ledger_name" => "Tally Customer",
      "party_gstin" => gstin,
      "place_of_supply" => "33",
      "line_items" => [line(taxable)]
    }
  end

  defp line(taxable) do
    %{
      "description" => "Consulting",
      "hsn_sac" => "9987",
      "taxable_value" => taxable,
      "cgst_rate" => 9.0,
      "cgst_amount" => taxable * 0.09,
      "sgst_rate" => 9.0,
      "sgst_amount" => taxable * 0.09
    }
  end

  defp totals(projection, invoice_number) do
    projection.invoices
    |> Enum.find(&(&1["invoice_number"] == invoice_number))
    |> get_in(["line_items", Access.at(0), "taxable_value"])
  end
end
