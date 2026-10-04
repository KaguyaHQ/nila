defmodule NilaWeb.SalesUploadResultControllerTest do
  use NilaWeb.ConnCase, async: true
  import NilaWeb.ApiContract, only: [contract_response: 2]
  import Ecto.Query
  import Nila.GstFixtures
  alias Nila.{Clients, Repo}
  alias Nila.Gst.Sales.{Batch, Derivation, Months}

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    dump = work_dump!(org, client, "2025-10", "sales", "%PDF-original", user.id) |> Repo.reload!()
    {:ok, batch} = Batch.create(org.id, client.id, Ecto.UUID.generate())
    dump = dump |> Ecto.Changeset.change(sales_batch_id: batch.id) |> Repo.update!()
    {:ok, :ok} = Repo.transact(fn -> {:ok, Derivation.refresh_in_transaction(dump)} end)

    %{
      conn: log_in_user(conn, user),
      user: user,
      org: org,
      client: client,
      dump: dump,
      ids: Enum.map(dump.invoices, & &1["id"]),
      path: "/api/workspace/sales/#{client.id}/2025-10/uploads/#{dump.id}"
    }
  end

  test "completed uploads expose skipped source documents without changing invoice identities",
       c do
    segment = %{
      "kind" => "non_invoice",
      "pages" => [6],
      "document_type" => "quotation",
      "reason" => "Quotation heading conflicts with printed invoice number."
    }

    meta =
      c.dump.meta
      |> Map.put("processing", %{"segments" => [segment]})
      |> Map.put("unaccounted_pages", [6])

    c.dump |> Ecto.Changeset.change(status: "extracted", meta: meta) |> Repo.update!()

    [file] = (c.conn |> get(c.path) |> contract_response(200))["files"]
    assert file["skipped_documents"] == [Map.delete(segment, "kind")]
    assert file["message"] =~ "not included as invoices"
    assert Enum.map(file["rows"], & &1["id"]) == c.ids
    assert file["completed"] == length(c.dump.invoices)
  end

  test "partial results identify the unread invoice and preserve completed review links", c do
    [first | _] = c.dump.invoices
    first = Map.put(first, "id", Nila.Gst.Sales.Processing.source_id(c.dump, 1))

    meta =
      Map.put(c.dump.meta, "processing", %{
        "segments" => [
          %{"kind" => "invoice", "pages" => [1], "invoice_no" => "ONE"},
          %{"kind" => "invoice", "pages" => [2], "invoice_no" => "TWO"}
        ],
        "failed" => [2],
        "artifacts" => %{"1" => %{"saved" => true}}
      })

    c.dump
    |> Ecto.Changeset.change(status: "failed", invoices: [first], meta: meta)
    |> Repo.update!()

    result = c.conn |> get(c.path) |> contract_response(200)
    assert result["processing"] == false
    [file] = result["files"]
    assert file["completed"] == 1
    assert file["total"] == 2
    assert [ready, failed] = file["rows"]
    assert ready["review_url"] =~ "/sales/invoices/"
    assert failed["state"] == "failed"
    assert failed["pages"] == [2]
    assert failed["review_url"] == nil

    assert c.conn |> post(c.path <> "/retry", %{dump_id: c.dump.id}) |> contract_response(200) ==
             %{"ok" => true}

    saved = Repo.reload!(c.dump)
    assert saved.status == "received"
    assert saved.invoices == [first]
    assert saved.meta["processing"]["artifacts"] == %{"1" => %{"saved" => true}}
    c.conn |> post(c.path <> "/retry", %{dump_id: c.dump.id}) |> contract_response(200)

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: fragment("?->>'dump_id'", j.args) == ^to_string(c.dump.id)
             ),
             :count
           ) == 1
  end

  test "including a skipped page appends its identity and records who confirmed it", c do
    segments =
      Enum.with_index(c.dump.invoices, 1)
      |> Enum.map(fn {_, index} ->
        %{"kind" => "invoice", "pages" => [index + 1], "invoice_no" => "OLD-#{index}"}
      end)

    skipped = %{"kind" => "non_invoice", "pages" => [1], "document_type" => "quotation"}

    artifacts =
      Map.new(Enum.with_index(c.dump.invoices, 1), fn {_, index} ->
        {to_string(index), %{"source_pages" => [index + 1]}}
      end)

    meta =
      Map.put(c.dump.meta, "processing", %{
        "segments" => [skipped | segments],
        "artifacts" => artifacts
      })

    c.dump |> Ecto.Changeset.change(status: "extracted", meta: meta) |> Repo.update!()

    body = %{
      dump_id: c.dump.id,
      pages: [1],
      reason: "Accountant confirmed the heading was copied by mistake."
    }

    c.conn |> post(c.path <> "/include-document", body) |> contract_response(200)
    saved = Repo.reload!(c.dump)
    assert Enum.map(saved.invoices, & &1["id"]) == c.ids
    assert Enum.take(saved.meta["processing"]["segments"], length(segments)) == segments

    assert Nila.Gst.Sales.Processing.artifact_ordinal(saved, %{"source_pages" => [1]}, 1) ==
             length(segments) + 1

    assert Nila.Gst.Sales.Processing.artifact_ordinal(saved, %{"source_pages" => [2]}, 2) == 1
    assert [override] = saved.meta["document_overrides"]
    assert override["user_id"] == c.user.id
    assert override["original_classification"] == skipped
    assert override["reason"] == body.reason
    c.conn |> post(c.path <> "/include-document", body) |> contract_response(409)

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: fragment("?->>'dump_id'", j.args) == ^to_string(c.dump.id)
             ),
             :count
           ) == 1
  end

  test "include refuses filed periods and viewers", c do
    {:ok, month} = Months.get_by_period(c.org.id, c.client.id, "2025-10")
    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()
    body = %{dump_id: c.dump.id, pages: [6], reason: "Confirmed invoice"}
    c.conn |> post(c.path <> "/include-document", body) |> contract_response(409)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.org_id == ^c.org.id and m.user_id == ^c.user.id),
      set: [role: "viewer"]
    )

    c.conn |> post(c.path <> "/include-document", body) |> contract_response(403)
  end

  test "retry refuses filed months and unrelated files", c do
    c.conn |> post(c.path <> "/retry", %{dump_id: c.dump.id + 1000}) |> contract_response(404)
    {:ok, month} = Months.get_by_period(c.org.id, c.client.id, "2025-10")
    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()
    c.conn |> post(c.path <> "/retry", %{dump_id: c.dump.id}) |> contract_response(409)
  end

  test "viewer reads progress but cannot retry, and foreign client is hidden", c do
    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.org_id == ^c.org.id and m.user_id == ^c.user.id),
      set: [role: "viewer"]
    )

    c.conn |> get(c.path) |> contract_response(200)
    c.conn |> post(c.path <> "/retry", %{dump_id: c.dump.id}) |> contract_response(403)
    %{user: outsider} = user_with_org_fixture()
    build_conn() |> log_in_user(outsider) |> get(c.path) |> contract_response(404)
  end
end
