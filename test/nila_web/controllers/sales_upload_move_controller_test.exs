defmodule NilaWeb.SalesUploadMoveControllerTest do
  use NilaWeb.ConnCase, async: true
  import NilaWeb.ApiContract, only: [contract_response: 2]
  import Nila.GstFixtures
  import Ecto.Query
  alias Nila.{Clients, Repo, Storage}
  alias Nila.Gst.Intake.{Dump, Dumps}
  alias Nila.Gst.Sales.{Batch, Derivation, Months}
  alias Nila.Gst.Sales.Invoice.{Correction, Corrections}
  alias Nila.Gst.Sales.Review.Resolutions

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, source} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, target} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Caltech",
        type: "company",
        gstin: "33BPPPK1081A1ZA"
      })

    dump = work_dump!(org, source, "2025-10", "sales", "%PDF-source", user.id) |> Repo.reload!()
    {:ok, batch} = Batch.create(org.id, source.id, Ecto.UUID.generate())

    invoices =
      Enum.map(dump.invoices, fn i ->
        i
        |> Map.put("seller_name", "Caltech")
        |> Map.put("seller_identity", %{
          "observed_gstin" => target.gstin,
          "client_gstin" => source.gstin,
          "status" => "different"
        })
      end)

    dump =
      dump
      |> Ecto.Changeset.change(sales_batch_id: batch.id, invoices: invoices)
      |> Repo.update!()

    {:ok, :ok} = Repo.transact(fn -> {:ok, Derivation.refresh_in_transaction(dump)} end)

    %{
      conn: log_in_user(conn, user),
      org: org,
      user: user,
      source: source,
      target: target,
      dump: dump,
      batch: batch,
      path: "/api/workspace/sales/#{source.id}/2025-10/uploads/#{dump.id}/move"
    }
  end

  test "move retains sources and corrections, rechecks seller, clears old approvals and rebuilds both clients",
       c do
    first = hd(c.dump.invoices)

    {:ok, _} =
      Corrections.save(
        c.org.id,
        c.source.id,
        to_string(c.dump.id),
        first["id"],
        %{"buyer_name" => "Corrected customer"},
        c.user.id
      )

    {:ok, source_month} = Months.get_by_period(c.org.id, c.source.id, "2025-10")

    {:ok, _} =
      Resolutions.record(
        source_month,
        %{verb: "confirm_issue", target: first["id"] <> ":seller_identity_mismatch"},
        c.user.id
      )

    before = c.conn |> get(c.path) |> contract_response(200)
    assert before["seller"]["gstin"] == c.target.gstin
    assert before["invoice_count"] == length(c.dump.invoices)

    body =
      c.conn
      |> post(c.path, %{destination_client_id: c.target.id, basis: before["basis"]})
      |> contract_response(200)

    assert body["client_id"] == c.target.id
    assert body["period"] == "2025-10"
    moved = Repo.reload!(c.dump)
    assert moved.client_id == c.target.id
    assert moved.file_keys == c.dump.file_keys
    assert Enum.map(moved.invoices, & &1["id"]) == Enum.map(c.dump.invoices, & &1["id"])

    assert Enum.all?(
             moved.invoices,
             &(&1["seller_gstin"] == c.target.gstin and
                 &1["seller_identity"]["status"] == "matched")
           )

    assert [%{"moved_by_id" => actor}] = moved.meta["client_moves"]
    assert actor == c.user.id
    assert Repo.reload!(c.batch).client_id == c.target.id

    assert [%Correction{client_id: client_id, corrected_by_id: actor}] =
             Corrections.list(c.org.id, c.target.id, first["id"])

    assert client_id == c.target.id and actor == c.user.id
    {:ok, source_month} = Months.get_by_period(c.org.id, c.source.id, "2025-10")
    assert source_month.invoices == []
    assert Resolutions.workings(source_month).active_invoices == []

    assert Resolutions.latest_decisions(source_month.id)[
             first["id"] <> ":seller_identity_mismatch"
           ].verb == "reopen"

    {:ok, target_month} = Months.get_by_period(c.org.id, c.target.id, "2025-10")
    effective = Resolutions.workings(target_month)

    assert Enum.find(effective.invoices, &(&1["id"] == first["id"]))["buyer_name"] ==
             "Corrected customer"

    refute Enum.any?(effective.issues, &(&1["code"] == "seller_identity_mismatch"))

    for i <- moved.invoices, image <- List.wrap(i["images"] || i["image"]) do
      name = Path.basename(image)
      assert {:ok, bytes} = Dumps.fetch_sales_evidence(c.org.id, c.target.id, moved.id, name)

      assert {:ok, ^bytes} =
               Storage.get(Months.evidence_key(c.org.id, c.source.id, "2025-10", name))

      assert {:error, :not_found} =
               Dumps.fetch_sales_evidence(c.org.id, c.source.id, moved.id, name)
    end

    # The original finalization token still identifies this upload after its assignment changes.
    token =
      Phoenix.Token.sign(NilaWeb.Endpoint, "sales PDF upload", %{
        org_id: c.org.id,
        user_id: c.user.id,
        client_id: c.source.id,
        period: "2025-10",
        import_ref: c.batch.import_ref
      })

    assert c.conn
           |> post("/api/workspace/sales/#{c.source.id}/2025-10/uploads", %{token: token})
           |> contract_response(200)
           |> Map.fetch!("ok") == true

    # Retry cannot duplicate a transfer or reassign another batch.
    assert c.conn
           |> post(c.path, %{destination_client_id: c.target.id, basis: before["basis"]})
           |> contract_response(404)
  end

  test "cannot move a subset of a multi-file upload", c do
    %Dump{org_id: c.org.id, client_id: c.source.id, sales_batch_id: c.batch.id}
    |> Dump.changeset(%{
      period: "2025-10",
      kind: "sales",
      status: "extracted",
      invoices: c.dump.invoices
    })
    |> Repo.insert!()

    assert c.conn |> get(c.path) |> contract_response(404)
  end

  test "mixed or unknown sellers are refused", c do
    i = hd(c.dump.invoices) |> Map.put("seller_identity", %{"observed_gstin" => c.source.gstin})
    c.dump |> Ecto.Changeset.change(invoices: c.dump.invoices ++ [i]) |> Repo.update!()
    assert c.conn |> get(c.path) |> contract_response(409)

    c.dump
    |> Ecto.Changeset.change(invoices: [Map.put(i, "seller_identity", %{})])
    |> Repo.update!()

    assert c.conn |> get(c.path) |> contract_response(409)
  end

  test "stale upload and wrong destination cannot change ownership", c do
    before = c.conn |> get(c.path) |> contract_response(200)

    assert c.conn
           |> post(c.path, %{destination_client_id: c.target.id, basis: "stale"})
           |> contract_response(409)

    assert c.conn
           |> post(c.path, %{destination_client_id: c.source.id, basis: before["basis"]})
           |> contract_response(409)

    {:ok, other} =
      Clients.create_client(%{
        org_id: c.org.id,
        name: "Other",
        type: "company",
        gstin: c.source.gstin
      })

    assert c.conn
           |> post(c.path, %{destination_client_id: other.id, basis: before["basis"]})
           |> contract_response(409)

    assert Repo.reload!(c.dump).client_id == c.source.id
    assert {:error, :not_found} = Months.get_by_period(c.org.id, c.target.id, "2025-10")
  end

  test "filed source and destination months refuse moves", c do
    before = c.conn |> get(c.path) |> contract_response(200)
    {:ok, month} = Months.get_by_period(c.org.id, c.source.id, "2025-10")
    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()

    assert c.conn
           |> post(c.path, %{destination_client_id: c.target.id, basis: before["basis"]})
           |> contract_response(409)

    month |> Ecto.Changeset.change(filed_at: nil) |> Repo.update!()
    {:ok, target} = Months.upsert(%{org_id: c.org.id, client_id: c.target.id, period: "2025-10"})
    target |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()

    assert c.conn
           |> post(c.path, %{destination_client_id: c.target.id, basis: before["basis"]})
           |> contract_response(409)

    assert Repo.reload!(c.dump).client_id == c.source.id
  end

  test "unfinished extraction cannot move", c do
    c.dump |> Ecto.Changeset.change(status: "extracting") |> Repo.update!()
    assert c.conn |> get(c.path) |> contract_response(409)
  end

  test "foreign clients and viewers cannot move documents", c do
    before = c.conn |> get(c.path) |> contract_response(200)
    %{org: foreign} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: foreign.id,
        name: "Foreign",
        type: "company",
        gstin: c.target.gstin
      })

    assert c.conn
           |> post(c.path, %{destination_client_id: client.id, basis: before["basis"]})
           |> contract_response(404)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.org_id == ^c.org.id and m.user_id == ^c.user.id),
      set: [role: "viewer"]
    )

    assert c.conn |> get(c.path) |> contract_response(403)

    assert c.conn
           |> post(c.path, %{destination_client_id: c.target.id, basis: before["basis"]})
           |> contract_response(403)

    assert Repo.reload!(c.dump).client_id == c.source.id
  end

  test "missing evidence rolls back ownership and destination month", c do
    invoice = hd(c.dump.invoices) |> Map.put("images", ["missing-move-evidence.png"])
    c.dump |> Ecto.Changeset.change(invoices: [invoice]) |> Repo.update!()
    before = c.conn |> get(c.path) |> contract_response(200)

    body =
      c.conn
      |> post(c.path, %{destination_client_id: c.target.id, basis: before["basis"]})
      |> contract_response(409)

    assert body["error"] =~ "Nothing was moved"
    assert Repo.reload!(c.dump).client_id == c.source.id
    assert Repo.reload!(c.batch).client_id == c.source.id
    assert {:error, :not_found} = Months.get_by_period(c.org.id, c.target.id, "2025-10")
  end

  test "a queued reread prevents moving an apparently finished upload", c do
    {:ok, _} = Oban.insert(Nila.Gst.Intake.DumpWorker.new(%{dump_id: c.dump.id}))
    assert c.conn |> get(c.path) |> contract_response(409)
  end

  test "a complete multi-file upload moves together", c do
    invoices = Enum.map(c.dump.invoices, fn i -> Map.put(i, "id", "second_" <> i["id"]) end)

    second =
      %Dump{org_id: c.org.id, client_id: c.source.id, sales_batch_id: c.batch.id}
      |> Dump.changeset(%{
        period: "2025-10",
        kind: "sales",
        status: "extracted",
        invoices: invoices,
        file_keys: c.dump.file_keys
      })
      |> Repo.insert!()

    path = "/api/workspace/sales/#{c.source.id}/2025-10/uploads/#{c.dump.id}-#{second.id}/move"
    before = c.conn |> get(path) |> contract_response(200)

    body =
      c.conn
      |> post(path, %{destination_client_id: c.target.id, basis: before["basis"]})
      |> contract_response(200)

    assert body["invoice_count"] == length(c.dump.invoices) * 2
    assert Repo.reload!(c.dump).client_id == c.target.id
    assert Repo.reload!(second).client_id == c.target.id
  end

  test "removed invoices stay removed and do not become the landing page", c do
    for i <- c.dump.invoices do
      {:ok, _} =
        Nila.Gst.Sales.Invoice.Removals.remove(
          c.org.id,
          c.source.id,
          to_string(c.dump.id),
          i["id"],
          c.user.id
        )
    end

    before = c.conn |> get(c.path) |> contract_response(200)

    body =
      c.conn
      |> post(c.path, %{destination_client_id: c.target.id, basis: before["basis"]})
      |> contract_response(200)

    assert body["review_url"] == "/gst/#{c.target.id}/2025-10/sales/register"
    {:ok, month} = Months.get_by_period(c.org.id, c.target.id, "2025-10")
    assert Resolutions.workings(month).active_invoices == []
  end
end
