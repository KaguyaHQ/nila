defmodule Nila.Gst.Sales.ImportsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.{Gstr1, Imports}

  test "groups one upload into a batch with its ready and review remainder" do
    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    ready_invoice =
      Gstr1.normalize_invoice(%{
        "data" => %{
          "document_type" => "invoice",
          "document_status" => "active",
          "supply_type" => "taxable",
          "recipient_registration" => "registered",
          "place_of_supply" => "29",
          "invoice_number" => "INV-001",
          "invoice_date" => "04.11.2025",
          "seller" => %{"gstin" => client.gstin},
          "buyer" => %{
            "name" => "Siemens Healthcare",
            "gstin" => "29AAVCS8021P1ZB"
          },
          "line_items" => [
            %{
              "description" => "Service",
              "hsn_sac" => "998719",
              "taxable_value" => 10_000,
              "igst_rate" => 18,
              "igst_amount" => 1_800
            }
          ],
          "printed_grand_total" => 11_800
        }
      })
      |> Map.put("id", "d1_inv_001")

    import_ref = Ecto.UUID.generate()

    {:ok, first} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{
          period: "2025-11",
          kind: "sales",
          status: "extracted",
          invoices: [ready_invoice],
          meta: %{"sales_import_ref" => import_ref}
        }
      )

    {:ok, second} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{
          period: "2025-11",
          kind: "sales",
          status: "failed",
          meta: %{"sales_import_ref" => import_ref}
        }
      )

    assert [row] = Imports.recent(org.id)
    assert row.batch_ref == "#{first.id}-#{second.id}"
    assert row.client_name == "Breeze Tech"
    assert row.invoice_count == 1
    assert row.ready_count == 1
    assert row.review_count == 1
  end
end
