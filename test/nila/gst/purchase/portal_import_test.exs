defmodule Nila.Gst.Purchase.PortalImportTest do
  use Nila.DataCase, async: true
  import Nila.AccountsFixtures
  alias Nila.Gst.Purchase.{Month, Months, PortalImport}
  alias Nila.Gst.Portal.Statement
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.{Repo, Storage}

  setup do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Portal purchase",
        gstin: "33AEWPH4158J1Z3",
        type: "company"
      })

    document = %{
      "data" => %{
        "gstin" => client.gstin,
        "rtnprd" => "082026",
        "docdata" => %{
          "b2b" => [
            %{
              "ctin" => "33AALCP2218B1ZX",
              "trdnm" => "Supplier",
              "inv" => [
                %{
                  "inum" => "INV-1",
                  "dt" => "05-08-2026",
                  "txval" => 1000,
                  "cgst" => 90,
                  "sgst" => 90,
                  "igst" => 0,
                  "val" => 1180,
                  "itcavl" => "Y"
                }
              ]
            }
          ]
        }
      }
    }

    statement =
      Repo.insert!(%Statement{
        client_id: client.id,
        gstin: client.gstin,
        period: "2026-08",
        document: document,
        fetched_at: DateTime.utc_now(),
        status: "ready"
      })

    %{scope: Nila.Accounts.Scope.for_user(user), org: org, client: client, statement: statement}
  end

  test "saved snapshot enters existing worker and repeated import is idempotent", c do
    assert {:ok, dump} = PortalImport.import(c.scope, c.client.id, "2026-08")
    assert {:ok, bytes} = Storage.get(hd(dump.file_keys))
    assert Jason.decode!(bytes) == c.statement.document
    assert {:ok, again} = PortalImport.import(c.scope, c.client.id, "2026-08")
    assert again.id == dump.id
    assert :ok = DumpWorker.perform(%Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1})
    assert {:ok, %{status: "extracted"}} = Dumps.fetch(c.org.id, dump.id)
    assert {:ok, month} = Months.get_by_period(c.org.id, c.client.id, "2026-08")
    assert month.recon != %{}
    assert [effective] = Dumps.effective(c.org.id, c.client.id, "2026-08", "gstr2b")
    assert hd(effective.invoices)["invoice_number"] == "INV-1"
  end

  test "a recomputed statement keeps the previous snapshot", c do
    assert {:ok, first} = PortalImport.import(c.scope, c.client.id, "2026-08")
    document = put_in(c.statement.document, ["data", "docdata", "b2b"], [])
    c.statement |> Ecto.Changeset.change(document: document) |> Repo.update!()
    assert {:ok, second} = PortalImport.import(c.scope, c.client.id, "2026-08")
    assert second.id != first.id
    assert {:ok, bytes} = Storage.get(hd(first.file_keys))
    assert Jason.decode!(bytes) == c.statement.document
  end

  test "unsupported sections are not silently omitted", c do
    document = put_in(c.statement.document, ["data", "docdata", "impg"], [%{"boe" => "123"}])
    c.statement |> Ecto.Changeset.change(document: document) |> Repo.update!()
    assert {:error, message} = PortalImport.import(c.scope, c.client.id, "2026-08")
    assert message =~ "impg"
    assert Dumps.list(c.org.id, c.client.id, "2026-08") == []
  end

  test "foreign client and read-only role cannot import", c do
    %{user: other} = user_with_org_fixture()

    assert {:error, :not_found} =
             PortalImport.import(Nila.Accounts.Scope.for_user(other), c.client.id, "2026-08")

    read_only = %{c.scope | membership: %{c.scope.membership | role: "viewer"}}
    assert {:error, :forbidden} = PortalImport.import(read_only, c.client.id, "2026-08")
  end

  test "filed month cannot be changed", c do
    Repo.insert!(%Month{
      org_id: c.org.id,
      client_id: c.client.id,
      period: "2026-08",
      state: "filed",
      filed_at: DateTime.utc_now()
    })

    assert {:error, message} = PortalImport.import(c.scope, c.client.id, "2026-08")
    assert message =~ "filed"
    assert Dumps.list(c.org.id, c.client.id, "2026-08") == []
  end

  test "missing or wrong month statement cannot import", c do
    assert {:error, message} = PortalImport.import(c.scope, c.client.id, "2026-07")
    assert message =~ "Fetch"
    document = put_in(c.statement.document, ["data", "rtnprd"], "072026")
    c.statement |> Ecto.Changeset.change(document: document) |> Repo.update!()
    assert {:error, message} = PortalImport.import(c.scope, c.client.id, "2026-08")
    assert message =~ "different return month"
  end

  test "a signed month cannot be changed", c do
    month = Repo.insert!(%Month{org_id: c.org.id, client_id: c.client.id, period: "2026-08"})

    Repo.insert!(%Nila.Gst.Filing.Signoff{
      org_id: c.org.id,
      client_month_id: month.id,
      signed_by_id: c.scope.user.id,
      snapshot: %{}
    })

    assert {:error, message} = PortalImport.import(c.scope, c.client.id, "2026-08")
    assert message =~ "signed off"
    assert Dumps.list(c.org.id, c.client.id, "2026-08") == []
  end

  test "same saved content retries a failed import without another source snapshot", c do
    assert {:ok, dump} = PortalImport.import(c.scope, c.client.id, "2026-08")
    Repo.update_all(Oban.Job, set: [state: "discarded"])
    Dumps.mark_failed(dump, "Temporary processing error")

    assert {:ok, retry} = PortalImport.import(c.scope, c.client.id, "2026-08")
    assert retry.id == dump.id
    assert retry.status == "received"
    assert retry.error == nil
    assert length(Dumps.list(c.org.id, c.client.id, "2026-08")) == 1
    assert Enum.count(Repo.all(Oban.Job), &(&1.state == "available")) == 1
    assert :ok = DumpWorker.perform(%Oban.Job{args: %{"dump_id" => dump.id}, attempt: 1})
    assert {:ok, %{status: "extracted"}} = Dumps.fetch(c.org.id, dump.id)
  end
end
