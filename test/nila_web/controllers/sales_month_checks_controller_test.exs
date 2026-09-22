defmodule NilaWeb.SalesMonthChecksControllerTest do
  use NilaWeb.ConnCase, async: true
  import Nila.GstFixtures
  import Ecto.Query
  alias Nila.{Clients, Repo}
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Gst.Sales.{Months, Workings}
  alias Nila.Gst.Sales.Review.Resolutions

  setup %{conn: conn} do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Month checks",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    dump =
      work_dump!(org, client, "2025-10", "sales", "%PDF-1.4 fake bytes", user.id)
      |> Repo.reload!()

    dump =
      dump
      |> Ecto.Changeset.change(
        meta:
          Map.merge(dump.meta, %{
            "unaccounted_pages" => [3],
            "evidence_unavailable" => true,
            "original_name" => "original.pdf"
          })
      )
      |> Repo.update!()

    {:ok, :derived} = DumpWorker.rederive(dump)
    {:ok, month} = Months.get_by_period(org.id, client.id, "2025-10")

    answer_sales_issues!(month, user.id,
      except: ~w(sequence_gaps pages_unaccounted evidence_unavailable)
    )

    %{
      conn: log_in_user(conn, user),
      org: org,
      user: user,
      client: client,
      dump: dump,
      month: month,
      path: "/api/workspace/sales/#{client.id}/2025-10/checks"
    }
  end

  test "specific checks expose original sources, confirm unlocks JSON, undo blocks it", %{
    conn: conn,
    path: path,
    client: client,
    dump: dump
  } do
    body = conn |> get(path) |> json_response(200)
    assert body["can_edit"]
    assert Enum.any?(body["checks"], &(&1["code"] == "pages_unaccounted"))
    assert Enum.any?(body["checks"], &(&1["code"] == "evidence_unavailable"))
    assert Enum.all?(body["checks"], &is_binary(&1["basis"]))
    pages = Enum.find(body["checks"], &(&1["code"] == "pages_unaccounted"))
    assert hd(pages["sources"])["url"] == "/gst/#{client.id}/2025-10/original/#{dump.id}/0"
    assert pages["confirm_label"] =~ "no bill was missed"
    json_path = "/gstr1/#{client.id}/2025-10/return.json"
    assert conn |> get(json_path) |> response(422)

    for check <- body["checks"] do
      assert conn |> post(path <> "/decision", decision(check, "confirm")) |> json_response(200)
    end

    assert conn |> get(json_path) |> json_response(200)
    assert conn |> post(path <> "/decision", decision(pages, "confirm")) |> json_response(409)

    resolved =
      conn
      |> get(path)
      |> json_response(200)
      |> Map.fetch!("checks")
      |> Enum.find(&(&1["target"] == pages["target"]))

    reopened =
      conn |> post(path <> "/decision", decision(resolved, "reopen")) |> json_response(200)

    assert conn |> get(json_path) |> response(422)
    assert conn |> post(path <> "/decision", decision(resolved, "reopen")) |> json_response(409)
    assert conn |> post(path <> "/decision", decision(pages, "confirm")) |> json_response(409)
    current = Enum.find(reopened["checks"], &(&1["target"] == pages["target"]))
    assert conn |> post(path <> "/decision", decision(current, "confirm")) |> json_response(200)
    assert conn |> post(path <> "/decision", decision(resolved, "reopen")) |> json_response(409)
  end

  test "changed pages and another same-name source invalidate saved confirmation and stale request",
       %{conn: conn, path: path, dump: dump, org: org, client: client} do
    check =
      conn
      |> get(path)
      |> json_response(200)
      |> Map.fetch!("checks")
      |> Enum.find(&(&1["code"] == "pages_unaccounted"))

    assert conn |> post(path <> "/decision", decision(check, "confirm")) |> json_response(200)

    dump =
      dump
      |> Ecto.Changeset.change(meta: Map.put(dump.meta, "unaccounted_pages", [3, 4]))
      |> Repo.update!()

    {:ok, :derived} = DumpWorker.rederive(dump)

    changed =
      conn
      |> get(path)
      |> json_response(200)
      |> Map.fetch!("checks")
      |> Enum.find(&(&1["code"] == "pages_unaccounted"))

    assert changed["status"] == "open"
    refute changed["basis"] == check["basis"]
    assert conn |> post(path <> "/decision", decision(check, "confirm")) |> json_response(409)
    assert conn |> post(path <> "/decision", decision(changed, "confirm")) |> json_response(200)

    {:ok, other} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{
        kind: "sales",
        period: "2025-10",
        status: "extracted",
        file_keys: ["another/original.pdf"],
        invoices: [],
        meta: %{"original_name" => "original.pdf", "unaccounted_pages" => [3, 4]}
      })

    {:ok, :derived} = DumpWorker.rederive(other)

    rows =
      conn
      |> get(path)
      |> json_response(200)
      |> Map.fetch!("checks")
      |> Enum.filter(&(&1["code"] == "pages_unaccounted"))

    assert length(rows) == 2
    assert Enum.all?(rows, &(&1["status"] == "open"))
    assert length(Enum.uniq_by(rows, & &1["target"])) == 2
  end

  test "legacy confirmation and arbitrary or invoice targets cannot clear packet checks", %{
    conn: conn,
    path: path,
    month: month,
    user: user
  } do
    issue = Enum.find(Resolutions.workings(month).issues, &(&1["code"] == "pages_unaccounted"))

    {:ok, _} =
      Resolutions.record(
        month,
        %{"verb" => "confirm_issue", "target" => Workings.issue_key(issue)},
        user.id
      )

    assert Enum.find(Resolutions.workings(month).issues, &(&1["code"] == "pages_unaccounted"))[
             "status"
           ] == "open"

    for target <- ["not-a-check", hd(month.invoices)["id"] <> ":arithmetic_mismatch"] do
      assert conn
             |> post(path <> "/decision", %{
               target: target,
               basis: issue["basis"],
               action: "confirm"
             })
             |> json_response(422)
    end

    assert conn
           |> post(path <> "/decision", %{
             target: Workings.issue_key(issue),
             basis: issue["basis"],
             action: "delete"
           })
           |> json_response(422)
  end

  test "tenant, viewer and filed protections apply to monthly decisions", %{
    conn: conn,
    path: path,
    month: month,
    user: user,
    org: org
  } do
    check = hd((conn |> get(path) |> json_response(200))["checks"])
    %{user: foreign} = user_with_org_fixture()
    assert build_conn() |> log_in_user(foreign) |> get(path) |> json_response(404)
    assert build_conn() |> get(path) |> json_response(401)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.user_id == ^user.id and m.org_id == ^org.id),
      set: [role: "viewer"]
    )

    refute (conn |> get(path) |> json_response(200))["can_edit"]
    assert conn |> post(path <> "/decision", decision(check, "confirm")) |> json_response(403)

    Repo.update_all(
      from(m in Nila.Orgs.Membership, where: m.user_id == ^user.id and m.org_id == ^org.id),
      set: [role: "owner"]
    )

    month |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()
    refute (conn |> get(path) |> json_response(200))["can_edit"]
    assert conn |> post(path <> "/decision", decision(check, "confirm")) |> json_response(409)
  end

  test "blocking packet issue is never exposed as a confirmable check", %{
    conn: conn,
    path: path,
    month: month
  } do
    check =
      conn
      |> get(path)
      |> json_response(200)
      |> Map.fetch!("checks")
      |> Enum.find(&(&1["code"] == "pages_unaccounted"))

    month
    |> Ecto.Changeset.change(
      issues:
        Enum.map(month.issues, fn issue ->
          if issue["code"] == "pages_unaccounted",
            do: Map.put(issue, "level", "blocking"),
            else: issue
        end)
    )
    |> Repo.update!()

    refute Enum.any?(
             (conn |> get(path) |> json_response(200))["checks"],
             &(&1["code"] == "pages_unaccounted")
           )

    assert conn |> post(path <> "/decision", decision(check, "confirm")) |> json_response(422)
  end

  defp decision(check, action),
    do: %{target: check["target"], basis: check["basis"], action: action}
end
