defmodule NilaWeb.SalesFlowTest do
  use NilaWeb.ConnCase, async: true
  use Oban.Testing, repo: Nila.Repo

  alias Nila.{Clients, Storage}
  alias Nila.Gst.Intake.{Dumps, DumpWorker}

  test "uploaded PDF reaches review and both outputs with its original source identity", %{
    conn: conn
  } do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Flow client",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    conn = log_in_user(conn, user)
    base = "/api/workspace/sales/#{client.id}/2025-10"
    bytes = "%PDF-1.4\nOffline extraction fixture\n%%EOF"

    prepared =
      conn
      |> post(base <> "/uploads/prepare", %{
        files: [%{name: "October bills.pdf", size: byte_size(bytes)}]
      })
      |> json_response(200)

    token =
      prepared["files"]
      |> hd()
      |> Map.fetch!("url")
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("token")

    {:ok, staging_key} = Storage.Local.verify_upload_token(token)
    {:ok, _} = Storage.put(staging_key, bytes, content_type: "application/pdf")

    assert conn |> post(base <> "/uploads", %{token: prepared["token"]}) |> json_response(200) ==
             %{"ok" => true}

    [dump] = Dumps.list(org.id, client.id, "2025-10")
    on_exit(fn -> Enum.each([staging_key | dump.file_keys], &Storage.delete/1) end)
    assert :ok = perform_job(DumpWorker, %{"dump_id" => dump.id})

    workspace = conn |> get(base) |> json_response(200)
    assert workspace["invoice_count"] == 3
    first = hd(workspace["rows"])
    invoice_path = base <> "/invoices/" <> URI.encode_www_form(first["id"])
    invoice = conn |> get(invoice_path) |> json_response(200)
    assert invoice["source"]["name"] == "October bills.pdf"
    assert invoice["source"]["url"] == "/gst/#{client.id}/2025-10/original/#{dump.id}/0"
    assert conn |> get(invoice["source"]["url"]) |> response(200) == bytes

    assert conn
           |> patch(invoice_path, %{section: "totals", values: %{printed_grand_total: "76171.36"}})
           |> json_response(200)

    assert conn
           |> patch(invoice_path, %{section: "facts", values: %{invoice_number: "19/2025-26"}})
           |> json_response(200)

    json_url = "/gstr1/#{client.id}/2025-10/return.json"
    xlsx_url = "/gstr1/#{client.id}/2025-10/workings.xlsx"
    assert conn |> get(json_url) |> response(422)
    assert conn |> get(xlsx_url) |> response(200)

    for row <- workspace["rows"] do
      review_path = base <> "/invoices/" <> URI.encode_www_form(row["id"])
      confirm_invoice(conn, review_path, 20)
    end

    checks = conn |> get(base <> "/checks") |> json_response(200)

    assert Enum.any?(
             checks["checks"],
             &(&1["code"] == "sequence_gaps" and &1["status"] == "open")
           )

    assert conn |> get(json_url) |> response(422)

    for check <- checks["checks"], check["status"] == "open" do
      assert conn
             |> post(base <> "/checks/decision", %{
               target: check["target"],
               basis: check["basis"],
               action: "confirm"
             })
             |> json_response(200)
    end

    result = conn |> get(json_url) |> json_response(200)
    assert result["gstin"] == client.gstin
    assert result["fp"] == "102025"

    details =
      for party <- result["b2b"],
          invoice <- party["inv"],
          item <- invoice["itms"],
          do: item["itm_det"]

    assert_in_delta Enum.sum(Enum.map(details, & &1["txval"])), 86_752, 0.01

    assert_in_delta Enum.sum(
                      Enum.map(
                        details,
                        &((&1["iamt"] || 0) + (&1["camt"] || 0) + (&1["samt"] || 0))
                      )
                    ),
                    15_615.36,
                    0.01

    ready = conn |> get(base) |> json_response(200)
    assert ready["review_count"] == 0
    assert ready["month_issue_count"] == 0
    assert ready["taxable"] == "₹86,752.00"
    assert ready["tax"] == "₹15,615.36"
    workbook = conn |> get(xlsx_url) |> response(200)
    {:ok, entries} = :zip.extract(workbook, [:memory])
    xml = entries |> Enum.map(&elem(&1, 1)) |> Enum.join()

    for row <- workspace["rows"] do
      assert xml =~ "/app/gst/#{client.id}/2025-10/sales/invoices/#{row["id"]}"
    end
  end

  defp confirm_invoice(_, _, 0), do: flunk("Invoice checks did not settle")

  defp confirm_invoice(conn, path, attempts) do
    body = conn |> get(path) |> json_response(200)

    case Enum.find(body["issues"], & &1["can_confirm"]) do
      nil ->
        :ok

      issue ->
        assert conn |> post(path <> "/confirm", %{target: issue["target"]}) |> json_response(200)
        confirm_invoice(conn, path, attempts - 1)
    end
  end
end
