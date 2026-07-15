defmodule Nila.Gst.MonthWorkerTest do
  use Nila.DataCase, async: true
  use Oban.Testing, repo: Nila.Repo

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.ClientMonths
  alias Nila.Gst.MonthWorker
  alias Nila.Storage

  @period "2025-10"

  setup do
    %{org: org} = user_with_org_fixture()
    {:ok, client} = Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    pdf_key = "gst/#{org.id}/#{client.id}/#{@period}/source/bills.pdf"
    gstr2b_key = "gst/#{org.id}/#{client.id}/#{@period}/source/gstr2b.json"
    {:ok, _} = Storage.put(pdf_key, "%PDF-1.4 fake bytes")
    {:ok, _} = Storage.put(gstr2b_key, gstr2b_json())

    %{org: org, client: client, pdf_key: pdf_key, gstr2b_key: gstr2b_key}
  end

  test "produces a worked client_month with sane buckets and stored evidence", %{
    org: org,
    client: client,
    pdf_key: pdf_key,
    gstr2b_key: gstr2b_key
  } do
    assert :ok =
             perform_job(MonthWorker, %{
               "org_id" => org.id,
               "client_id" => client.id,
               "period" => @period,
               "pdf_key" => pdf_key,
               "gstr2b_key" => gstr2b_key
             })

    assert {:ok, month} = ClientMonths.get_by_period(org.id, client.id, @period)
    assert month.state == "worked"

    buckets = month.summary["buckets"]
    assert buckets["matched"] >= 1
    assert buckets["needs_human"] >= 1
    assert buckets["in_books_not_2b"] >= 1
    assert buckets["in_2b_not_books"] >= 1

    needs_human =
      Enum.filter(month.register_rows, &(&1["bucket"] == "needs_human"))

    assert needs_human != []

    row_with_image = Enum.find(month.register_rows, &(&1["images"] not in [nil, []]))
    assert row_with_image
    [basename | _] = Enum.map(row_with_image["images"], &Path.basename/1)

    assert {:ok, bytes} = ClientMonths.fetch_evidence(org.id, client.id, @period, basename)
    assert byte_size(bytes) > 0
  end

  # A GSTR-2B that reconciles against the stub extractor's three invoices:
  # DPS-0072 matches exactly; INTER COOL's invoice number disagrees (→
  # needs_human); MONY STORES is absent (→ in_books_not_2b); an unknown vendor
  # is 2B-only (→ in_2b_not_books).
  defp gstr2b_json do
    Jason.encode!(%{
      "data" => %{
        "docdata" => %{
          "b2b" => [
            supplier("32AAMFD7558A1ZL", "DAWN POWER SOLUTIONS", [
              invoice("DPS-0072", "08-10-2025", 20_060.0, 17_000.0, 3060.0)
            ]),
            supplier("32ACVPR7455F1Z3", "INTER COOL REFRIGERATION", [
              invoice("GX999", "12-10-2025", 949.99, 805.08, 144.91)
            ]),
            supplier("29AAACS9999A1Z5", "PHANTOM SUPPLIES", [
              invoice("PS-1", "05-10-2025", 5900.0, 5000.0, 900.0)
            ])
          ]
        }
      }
    })
  end

  defp supplier(ctin, trdnm, invoices),
    do: %{"ctin" => ctin, "trdnm" => trdnm, "inv" => invoices}

  defp invoice(inum, dt, val, txval, igst) do
    %{
      "inum" => inum,
      "dt" => dt,
      "val" => val,
      "pos" => "33",
      "rev" => "N",
      "itcavl" => "Y",
      "txval" => txval,
      "igst" => igst,
      "cgst" => 0,
      "sgst" => 0
    }
  end
end
