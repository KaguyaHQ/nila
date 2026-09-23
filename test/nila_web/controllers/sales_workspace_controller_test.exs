defmodule NilaWeb.SalesWorkspaceControllerTest do
  import NilaWeb.ApiContract, only: [contract_response: 2]
  use NilaWeb.ConnCase, async: true
  import Nila.GstFixtures

  alias Nila.Clients
  alias Nila.Gst.Sales.{Months, Review}
  alias Nila.Gst.Sales.Review.{Resolutions, Values}
  alias NilaWeb.Components.Gst.Month.{Helpers, SalesWorkspace}

  setup %{conn: conn} do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Sales firm client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    work_dump!(org, client, "2025-10", "sales", "%PDF-1.4 fake bytes", user.id)
    %{conn: log_in_user(conn, user), client: client, org: org}
  end

  test "returns the effective working and the same summary as LiveView", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, month} = Months.get_by_period(org.id, client.id, "2025-10")
    working = Resolutions.effective_workings(month)
    body = conn |> get("/api/workspace/sales/#{client.id}/2025-10") |> contract_response(200)
    assert body["client"]["id"] == client.id
    assert body["taxable"] == Helpers.rupees(Values.filed_totals(working.derived).taxable)
    assert body["tax"] == Helpers.rupees(Values.filed_totals(working.derived).tax)
    assert body["invoice_count"] == length(working.active_invoices)
    assert body["review_count"] == length(Review.build(working).needs_you)

    assert body["sections"] ==
             SalesWorkspace.summary_rows(working, client, "2025-10")
             |> Jason.encode!()
             |> Jason.decode!()

    assert Enum.map(body["rows"], & &1["id"]) == Enum.map(working.source_invoices, & &1["id"])

    assert Enum.all?(body["rows"], fn row ->
             row["path"] ==
               "/gst/#{client.id}/2025-10/sales/invoices/#{URI.encode_www_form(row["id"])}"
           end)

    assert body["uploads"]["files"] == 1
    assert body["user"]["org"] == org.name
  end

  test "an empty month is valid without fixture invoices", %{conn: conn, client: client} do
    response = get(conn, "/api/workspace/sales/#{client.id}/2026-01")
    body = contract_response(response, 200)
    assert body["rows"] == []
    assert body["invoice_count"] == 0
    assert body["taxable"] == "—"
    assert Enum.all?(body["sections"], &(&1["count"] == "—"))
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
  end

  test "filed snapshots retain totals and excluded sources cannot open another invoice", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, month} = Months.get_by_period(org.id, client.id, "2025-10")
    [invoice | _] = month.invoices
    excluded = invoice |> Map.put("id", "excluded-copy") |> Map.put("duplicate_copy", true)

    month
    |> Ecto.Changeset.change(invoices: month.invoices ++ [excluded], filed_at: DateTime.utc_now())
    |> Nila.Repo.update!()

    body = conn |> get("/api/workspace/sales/#{client.id}/2025-10") |> contract_response(200)
    assert body["tax"] == Helpers.rupees(Values.filed_totals(month.derived_gstr1).tax)
    row = Enum.find(body["rows"], &(&1["id"] == "excluded-copy"))
    assert row["status"] == "excluded"
    assert row["path"] == nil
  end

  test "a different firm cannot read the client", %{conn: conn, client: client} do
    %{user: other} = user_with_org_fixture()

    response =
      conn |> recycle() |> log_in_user(other) |> get("/api/workspace/sales/#{client.id}/2025-10")

    assert contract_response(response, 404) == %{"error" => "This client is not available."}
  end

  test "signed-out requests receive JSON, not login HTML", %{client: client} do
    response = build_conn() |> get("/api/workspace/sales/#{client.id}/2025-10")
    assert contract_response(response, 401) == %{"error" => "Sign in to continue."}
  end

  test "invalid client identifiers and periods do not reach Ecto", %{conn: conn, client: client} do
    for url <- [
          "/api/workspace/sales/nope/2025-10",
          "/api/workspace/sales/#{client.id}/2025-13",
          "/api/workspace/sales/#{client.id}/bad"
        ] do
      assert conn |> get(url) |> contract_response(400) == %{
               "error" => "Choose a valid client and month."
             }
    end
  end

  test "React pages require the existing login", %{client: client} do
    for page <- ~w(register upload uploads) do
      response = build_conn() |> get("/app/gst/#{client.id}/2025-10/sales/#{page}")
      assert redirected_to(response) == "/users/log_in"
    end
  end

  test "detail tables expose formatted section rows, HSN contributors and source document series",
       %{conn: conn, client: client} do
    body = conn |> get("/api/workspace/sales/#{client.id}/2025-10") |> contract_response(200)
    assert Enum.sort(Map.keys(body["details"])) == ~w(b2b b2cl b2cs cdnr documents exp hsn sez)
    rows = get_in(body, ["details", "b2b", "groups"]) |> hd() |> Map.fetch!("rows")
    assert rows != []
    assert Enum.all?(rows, &String.contains?(&1["invoice_path"], "/sales/invoices/"))

    assert Enum.all?(rows, fn row ->
             Enum.all?(row["cells"], fn {_, value} -> is_binary(value) end)
           end)

    hsn = get_in(body, ["details", "hsn", "groups"]) |> hd() |> Map.fetch!("rows")
    assert hsn != []
    assert Enum.any?(hsn, &(&1["children"] != []))
    assert body["details"]["documents"]["note"] =~ "does not prove"
    assert Enum.map(body["exports"]["items"], & &1["id"]) == ["workings", "json"]
  end

  test "filed details retain stored invoice and HSN figures when source values differ", %{
    conn: conn,
    client: client,
    org: org
  } do
    {:ok, month} = Months.get_by_period(org.id, client.id, "2025-10")
    invoice = hd(month.invoices)

    snapshot = %{
      "gstin" => client.gstin,
      "fp" => "102025",
      "b2b" => [
        %{
          "ctin" => invoice["buyer_gstin"],
          "inv" => [
            %{
              "inum" => invoice["invoice_number"],
              "idt" => "01-10-2025",
              "inv_typ" => "R",
              "itms" => [%{"itm_det" => %{"txval" => 4321.0, "iamt" => 777.78}}]
            }
          ]
        }
      ],
      "hsn" => %{
        "hsn_b2b" => [
          %{
            "hsn_sc" => "998719",
            "rt" => 18,
            "txval" => 4321.0,
            "iamt" => 777.78,
            "qty" => 1,
            "uqc" => "OTH"
          }
        ]
      }
    }

    month
    |> Ecto.Changeset.change(filed_at: DateTime.utc_now(), derived_gstr1: snapshot)
    |> Nila.Repo.update!()

    body = conn |> get("/api/workspace/sales/#{client.id}/2025-10") |> contract_response(200)
    [row] = body["details"]["b2b"]["groups"] |> hd() |> Map.fetch!("rows")
    assert row["cells"]["taxable"] == Helpers.rupees(4321.0)
    assert row["cells"]["tax"] == Helpers.rupees(777.78)
    [hsn] = body["details"]["hsn"]["groups"] |> hd() |> Map.fetch!("rows")
    assert hsn["cells"]["taxable"] == Helpers.rupees(4321.0)
    assert hsn["cells"]["tax"] == Helpers.rupees(777.78)
    refute Map.has_key?(hsn, "children")
  end

  test "sales contract rejects missing fields and wrong count types", %{
    conn: conn,
    client: client
  } do
    body = conn |> get("/api/workspace/sales/#{client.id}/2026-01") |> contract_response(200)

    assert {:error, _} =
             NilaWeb.ApiContract.validate("SalesWorkspace", Map.delete(body, "exports"))

    assert {:error, _} =
             NilaWeb.ApiContract.validate(
               "SalesWorkspace",
               Map.put(body, "invoice_count", "0")
             )
  end
end
