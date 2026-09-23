defmodule NilaWeb.PurchaseReviewControllerTest do
  import NilaWeb.ApiContract, only: [contract_response: 2]
  use NilaWeb.ConnCase, async: true
  import Nila.GstFixtures
  import Ecto.Query
  alias Nila.Gst.Purchase.{Months, Reconciliation, Register, Resolutions}
  alias Nila.Repo

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Purchase review API",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      path: "/api/workspace/purchases/#{client.id}/2026-08/review"
    }
  end

  test "2B-only comparison records document then claims with fresh tokens", c do
    seed(c, [], [invoice(nil, "PORTAL")])
    body = c.conn |> get(c.path) |> contract_response(200)
    [line] = body["cases"]
    refute body["books_available"]
    assert body["item"]["status"] == "Not compared"
    assert body["item"]["reason"] =~ "not been compared"
    assert hd(body["queue"])["tax"] == "₹1,800.00"
    [comparison] = body["item"]["comparisons"]
    refute comparison["has_books"]
    assert comparison["has_portal"]
    assert line["can_record_document"]
    refute line["claimable"]
    assert length(line["heads"]) == 3

    assert hd(body["item"]["comparisons"])["facts"]
           |> Enum.any?(&(&1["label"] == "Invoice number" and &1["portal"] == "PORTAL"))

    path = c.path <> "/" <> URI.encode_www_form(body["item"]["id"])

    assert c.conn
           |> post(path <> "/treatment", payload([line], %{choice: "claim"}))
           |> contract_response(422)

    held =
      c.conn
      |> post(path <> "/document", Map.delete(payload([line], %{}), :values))
      |> contract_response(200)

    [fresh] = held["cases"]
    assert fresh["claimable"]
    assert fresh["document_state"] == "held"
    refute fresh["basis"] == line["basis"]

    assert c.conn
           |> post(path <> "/treatment", payload([line], %{choice: "claim"}))
           |> contract_response(409)

    claimed =
      c.conn
      |> post(path <> "/treatment", payload([fresh], %{choice: "claim"}))
      |> contract_response(200)

    assert hd(claimed["cases"])["values"]["choice"] == "claim"

    summary =
      c.conn
      |> get("/api/workspace/purchases/#{c.client.id}/2026-08")
      |> contract_response(200)

    assert summary["overview"]["itc"]["claim"] == "₹1,800.00"
    assert summary["overview"]["itc"]["pending"] == "₹0.00"

    workbook =
      c.conn
      |> get("/gst/#{c.client.id}/2026-08/purchases/workings.xlsx")
      |> response(200)

    {:ok, entries} = :zip.unzip(workbook, [:memory])
    files = Map.new(entries, fn {name, bytes} -> {to_string(name), bytes} end)
    strings = Regex.scan(~r/<si\b[^>]*>(.*?)<\/si>/s, files["xl/sharedStrings.xml"])
    claim_index = Enum.find_index(strings, fn [_, text] -> text =~ ">Claim this period<" end)
    assert is_integer(claim_index)

    claim_row =
      Regex.scan(~r/<row\b[^>]*>.*?<\/row>/s, files["xl/worksheets/sheet1.xml"])
      |> List.flatten()
      |> Enum.find(&String.contains?(&1, "<v>#{claim_index}</v>"))

    assert claim_row =~ ~r/<v>1800(?:\.0+)?<\/v>/

    assert c.conn
           |> post(path <> "/treatment", payload([fresh], %{choice: "claim"}))
           |> contract_response(409)
  end

  test "bulk Later requires structured reason and Other note, then carried month remains actionable",
       c do
    seed(c, [], [invoice(nil, "ONE"), invoice(nil, "TWO")])
    body = c.conn |> get(c.path) |> contract_response(200)
    lines = body["cases"]
    assert length(lines) == 2

    assert c.conn
           |> post(c.path <> "/treatment", payload(lines, %{choice: "later"}))
           |> contract_response(422)

    assert c.conn
           |> post(
             c.path <> "/treatment",
             payload(lines, %{choice: "later", later_reason: "other"})
           )
           |> contract_response(422)

    assert c.conn
           |> post(
             c.path <> "/treatment",
             payload(lines, %{
               choice: "later",
               later_reason: "review_pending",
               note: "Check originals"
             })
           )
           |> contract_response(200)

    september = String.replace(c.path, "2026-08", "2026-09")
    carried = c.conn |> get(september, %{filter: "carried"}) |> contract_response(200)
    assert length(carried["queue"]) == 2
    assert String.starts_with?(carried["item"]["id"], "case-")

    assert hd(carried["item"]["comparisons"])["facts"]
           |> Enum.any?(&(&1["label"] == "Invoice number" and &1["portal"] in ["ONE", "TWO"]))

    [line | _] = carried["cases"]
    assert line["available"]
    assert line["values"]["choice"] == "later"

    assert c.conn
           |> post(
             september <> "/treatment?filter=carried",
             payload([line], %{choice: "later", later_reason: "review_pending"})
           )
           |> contract_response(200)
  end

  test "cess cannot be claimed or deferred, but split can exclude cess and claim ordinary heads",
       c do
    row = invoice("BOOK", "CESS") |> put_in(["tax_paise", "cess"], 2_000)
    seed(c, [row], [Map.delete(row, "id")])
    body = c.conn |> get(c.path) |> contract_response(200)
    [line] = body["cases"]
    assert line["cess_issue"] =~ "cess"
    refute line["claimable"]
    assert line["can_claim_split"]

    for choice <- ~w(claim later) do
      response =
        c.conn
        |> post(
          c.path <> "/treatment",
          payload([line], %{choice: choice, later_reason: "review_pending"})
        )
        |> contract_response(422)

      assert response["code"] == "cess_review_required"
    end

    split = %{
      claim: %{cgst: "900.00", sgst: "900.00", igst: "0.00", cess: "0.00"},
      later: %{cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00"},
      exclude: %{cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "20.00"}
    }

    saved =
      c.conn
      |> post(
        c.path <> "/treatment",
        payload([line], %{choice: "split", split: split, exclude_reason: "blocked_credit"})
      )
      |> contract_response(200)

    assert hd(saved["cases"])["values"]["split"]["exclude"]["cess"] == "20.00"
  end

  test "changed source amounts make token stale",
       c do
    month = seed(c, [invoice("BOOK", "A")], [invoice(nil, "A")])
    body = c.conn |> get(c.path) |> contract_response(200)
    [line] = body["cases"]

    attrs = [
      %{
        "verb" => "correct_field",
        "books_id" => "BOOK",
        "payload" => %{
          "field" => "tax_paise",
          "from" => invoice("BOOK", "A")["tax_paise"],
          "to" => %{"cgst" => 99_000, "sgst" => 90_000, "igst" => 0},
          "reason" => "Printed amount"
        }
      }
    ]

    assert {:ok, _} = Resolutions.record_many_and_refresh(month, attrs, c.user.id)

    assert c.conn
           |> post(
             c.path <> "/treatment",
             payload([line], %{choice: "later", later_reason: "review_pending"})
           )
           |> contract_response(409)
  end

  test "no fallback invoice, tenant, viewer and signed-off guards", c do
    month = seed(c, [], [invoice(nil, "ONE")])
    body = c.conn |> get(c.path) |> contract_response(200)
    [line] = body["cases"]
    assert c.conn |> get(c.path <> "/unknown") |> contract_response(404)
    %{user: other} = user_with_org_fixture()
    assert build_conn() |> log_in_user(other) |> get(c.path) |> contract_response(404)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.user_id == ^c.user.id and m.org_id == ^c.org.id),
      set: [role: "viewer"]
    )

    refute (c.conn |> get(c.path) |> contract_response(200))["can_edit"]

    assert c.conn
           |> post(c.path <> "/treatment", payload([line], %{choice: "later"}))
           |> contract_response(403)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.user_id == ^c.user.id and m.org_id == ^c.org.id),
      set: [role: "owner"]
    )

    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()

    assert c.conn
           |> post(c.path <> "/treatment", payload([line], %{choice: "later"}))
           |> contract_response(409)
  end

  test "uncertain pairing blocks forged treatment and exposes source comparison", c do
    seed(c, [invoice("BOOK", "1134")], [invoice(nil, "CHN-SER-1134")])
    body = c.conn |> get(c.path) |> contract_response(200)
    assert body["item"]["pairing_pending"]
    assert body["cases"] != []
    assert Enum.all?(body["cases"], &(not &1["available"]))

    response =
      c.conn
      |> post(
        c.path <> "/" <> URI.encode_www_form(body["item"]["id"]) <> "/treatment",
        payload(body["cases"], %{choice: "later", later_reason: "review_pending"})
      )
      |> contract_response(422)

    assert response["code"] == "pairing_pending"
  end

  test "malformed and unbalanced split values do not write", c do
    seed(c, [], [invoice(nil, "ONE")])
    body = c.conn |> get(c.path) |> contract_response(200)

    for split <- ["bad", %{claim: "bad"}, %{claim: %{cgst: "-1"}, later: %{}, exclude: %{}}] do
      assert c.conn
             |> post(
               c.path <> "/treatment",
               payload(body["cases"], %{choice: "split", split: split})
             )
             |> contract_response(422)
    end

    values = %{choice: "split", split: %{claim: %{}, later: %{}, exclude: %{}}}

    response =
      c.conn
      |> post(c.path <> "/treatment", payload(body["cases"], values))
      |> contract_response(422)

    assert response["code"] == "amounts_do_not_balance"

    assert hd((c.conn |> get(c.path) |> contract_response(200))["cases"])["values"]["choice"] ==
             nil
  end

  test "carried original uses its upload month and settled cases leave Needs review", c do
    key = "tests/carried/#{Ecto.UUID.generate()}.xlsx"
    {:ok, _} = Nila.Storage.put(key, "original workbook")
    on_exit(fn -> Nila.Storage.delete(key) end)

    {:ok, dump} =
      Nila.Gst.Intake.Dumps.record(%{org_id: c.org.id, client_id: c.client.id}, %{
        period: "2026-08",
        kind: "purchase",
        status: "extracted",
        file_keys: [key],
        invoices: []
      })

    row = invoice("d#{dump.id}_excel_1", "CARRIED")
    seed(c, [row], [Map.delete(row, "id")])
    body = c.conn |> get(c.path) |> contract_response(200)

    assert c.conn
           |> post(
             c.path <> "/treatment",
             payload(body["cases"], %{choice: "later", later_reason: "review_pending"})
           )
           |> contract_response(200)

    september = String.replace(c.path, "2026-08", "2026-09")
    carried = c.conn |> get(september, %{filter: "needs_review"}) |> contract_response(200)
    assert length(carried["queue"]) == 1
    assert hd(carried["queue"])["origin_period"] == "2026-08"
    url = hd(carried["item"]["comparisons"])["original_url"]
    assert url == "/gst/#{c.client.id}/2026-08/original/#{dump.id}/0"
    assert c.conn |> get(url) |> response(200) == "original workbook"

    result =
      c.conn
      |> post(
        september <> "/treatment?filter=needs_review",
        payload(carried["cases"], %{choice: "claim"})
      )
      |> contract_response(200)

    assert result["queue"] == []
    assert result["item"] == nil
    all = c.conn |> get(september, %{filter: "carried"}) |> contract_response(200)
    assert length(all["queue"]) == 1
    refute hd(all["queue"])["needs_review"]
  end

  test "source correction keeps audit evidence and refuses stale and foreign sources", c do
    month = seed(c, [invoice("BOOK", "ONE")], [invoice(nil, "ONE")])
    body = c.conn |> get(c.path, %{filter: "all"}) |> contract_response(200)
    pair = hd(body["item"]["comparisons"])
    path = c.path <> "/" <> URI.encode_www_form(body["item"]["id"]) <> "/source?filter=all"

    attrs = %{
      action: "correct",
      books_id: "BOOK",
      source_basis: body["item"]["source_basis"],
      amounts:
        Map.merge(pair["correction"], %{
          "taxable_paise" => "11000.00",
          "total_paise" => "12800.00"
        }),
      reason: "Verified original invoice"
    }

    c.conn |> post(path, %{attrs | books_id: "foreign"}) |> contract_response(422)
    c.conn |> post(path, %{attrs | source_basis: "stale"}) |> contract_response(409)
    c.conn |> post(path, %{attrs | reason: ""}) |> contract_response(422)

    c.conn
    |> post(path, %{attrs | amounts: Map.put(attrs.amounts, "total_paise", "1.00")})
    |> contract_response(422)

    assert Resolutions.list(month.id) == []
    fresh = c.conn |> post(path, attrs) |> contract_response(200)
    assert fresh["item"]
    events = Resolutions.list(month.id)
    assert length(events) == 2
    assert Enum.all?(events, &(&1.payload["reason"] == "Verified original invoice"))
    assert Enum.any?(events, &(&1.payload["from"] == 1_000_000 && &1.payload["to"] == 1_100_000))
    c.conn |> post(path, attrs) |> contract_response(409)
  end

  test "suggested pairing can be confirmed or rejected with current source basis", c do
    month = seed(c, [invoice("BOOK", "INV-123")], [invoice(nil, "INV-128")])
    body = c.conn |> get(c.path, %{filter: "all"}) |> contract_response(200)
    pair = hd(body["item"]["comparisons"])
    assert pair["can_pair"]
    refute hd(body["queue"])["bulk_eligible"]
    path = c.path <> "/" <> URI.encode_www_form(body["item"]["id"]) <> "/source?filter=all"

    attrs = %{
      action: "confirm_pair",
      books_id: "BOOK",
      portal_ref: pair["portal_ref"],
      source_basis: body["item"]["source_basis"]
    }

    c.conn |> post(path, %{attrs | portal_ref: "foreign"}) |> contract_response(422)
    c.conn |> post(path, %{attrs | source_basis: "stale"}) |> contract_response(409)
    c.conn |> post(path, attrs) |> contract_response(200)
    assert Enum.any?(Resolutions.list(month.id), &(&1.verb == "confirm_pair"))
  end

  test "suggested pairing can be rejected without confirming or claiming it", c do
    month = seed(c, [invoice("BOOK", "INV-123")], [invoice(nil, "INV-128")])
    body = c.conn |> get(c.path, %{filter: "all"}) |> contract_response(200)
    pair = hd(body["item"]["comparisons"])
    assert pair["can_pair"]
    refute hd(body["queue"])["bulk_eligible"]
    path = c.path <> "/" <> URI.encode_www_form(body["item"]["id"]) <> "/source?filter=all"

    attrs = %{
      action: "reject_pair",
      books_id: "BOOK",
      portal_ref: pair["portal_ref"],
      source_basis: body["item"]["source_basis"]
    }

    c.conn |> post(path, %{attrs | portal_ref: "foreign"}) |> contract_response(422)
    c.conn |> post(path, %{attrs | source_basis: "stale"}) |> contract_response(409)
    c.conn |> post(path, attrs) |> contract_response(200)
    assert Enum.any?(Resolutions.list(month.id), &(&1.verb == "reject_pair"))
  end

  test "bulk endpoint refuses differences without writing any treatments", c do
    changed = invoice("BOOK", "ONE") |> Map.put("taxable_paise", 2_000_000)
    seed(c, [changed], [invoice(nil, "ONE")])
    body = c.conn |> get(c.path, %{filter: "all"}) |> contract_response(200)
    refute hd(body["queue"])["bulk_eligible"]

    result =
      c.conn
      |> post(
        c.path <> "/bulk-treatment?filter=all",
        payload(body["cases"], %{choice: "later", later_reason: "review_pending"})
      )
      |> contract_response(422)

    assert result["code"] == "individual_review_required"
  end

  test "bulk treatment is atomic when one selected basis is stale", c do
    seed(c, [], [invoice(nil, "ONE"), invoice(nil, "TWO")])
    body = c.conn |> get(c.path, %{filter: "all"}) |> contract_response(200)
    assert Enum.all?(body["queue"], & &1["bulk_eligible"])
    attrs = payload(body["cases"], %{choice: "later", later_reason: "review_pending"})
    id = hd(body["cases"])["id"] |> to_string()
    stale = %{attrs | basis: Map.put(attrs.basis, id, "stale")}
    c.conn |> post(c.path <> "/bulk-treatment?filter=all", stale) |> contract_response(409)
    unchanged = c.conn |> get(c.path, %{filter: "all"}) |> contract_response(200)
    assert Enum.all?(unchanged["cases"], &is_nil(&1["values"]["choice"]))

    saved =
      c.conn |> post(c.path <> "/bulk-treatment?filter=all", attrs) |> contract_response(200)

    assert Enum.all?(saved["cases"], &(&1["values"]["choice"] == "later"))
  end

  defp payload(lines, values),
    do: %{
      case_ids: Enum.map(lines, & &1["id"]),
      basis: Map.new(lines, &{to_string(&1["id"]), &1["basis"]}),
      values: values
    }

  defp invoice(id, number),
    do: %{
      "id" => id,
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => "33AALCP2218B1ZX",
      "invoice_number" => number,
      "invoice_date" => "2026-08-05",
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
      "total_paise" => 1_180_000,
      "images" => [],
      "pos" => "33"
    }

  defp seed(c, books, portal) do
    gstr2b_arrived!(c.org, c.client, "2026-08", portal)
    recon = Reconciliation.reconcile(books, portal)
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: c.org.id,
        client_id: c.client.id,
        period: "2026-08",
        state: "worked",
        recon: recon,
        register_rows: rows,
        summary: Register.summary(rows)
      })

    month
  end
end
