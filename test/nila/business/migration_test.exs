defmodule Nila.Business.MigrationTest do
  use Nila.DataCase, async: true

  import Ecto.Query
  import Nila.AccountsFixtures

  alias Nila.Business.{
    ClientAccess,
    Customer,
    CustomerAddress,
    Invoice,
    Invoicing,
    Migration,
    Service
  }

  alias Nila.Repo

  setup do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Delhi Service Business",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    {:ok, _profile} =
      Invoicing.save_profile(client, %{
        legal_name: "Delhi Service Business",
        address: "Chennai",
        state_code: "33"
      })

    %ClientAccess{user_id: user.id, client_id: client.id}
    |> ClientAccess.changeset()
    |> Repo.insert!()

    %{actor_id: user.id, client: client}
  end

  test "previews and idempotently applies a complete packet without changing live numbering",
       ctx do
    packet = packet()

    assert {:ok, preview} = Migration.preview(ctx.client, packet)
    assert preview.ready?
    assert preview.counts == %{customers: 1, quotations: 1, services: 2}
    assert preview.existing_numbers == []

    assert {:ok, first} =
             Migration.apply_packet(ctx.client, ctx.actor_id, packet,
               render_pdf: fn snapshot -> {:ok, "%PDF-migration " <> snapshot["number"]} end
             )

    assert [%{action: :created}] = first.customers
    assert [%{action: :created}, %{action: :created}] = first.services
    assert [%{action: :created, number: "57/2026-27"}] = first.quotations

    quote = Repo.get_by!(Invoice, client_id: ctx.client.id, number: "57/2026-27")
    assert quote.status == "issued"
    assert quote.snapshot["totals"]["total_paise"] == 3_127_000
    assert quote.snapshot["delivery_address"] == "PH Diagnostic Centre\nHadapsar, Pune 411002"
    assert Repo.aggregate(from(c in Customer, where: c.client_id == ^ctx.client.id), :count) == 1
    assert Repo.aggregate(from(s in Service, where: s.client_id == ^ctx.client.id), :count) == 2

    assert Repo.aggregate(
             from(a in CustomerAddress, where: a.client_id == ^ctx.client.id),
             :count
           ) == 2

    assert Invoicing.quotation_numbering(ctx.client).next_number == 1

    assert {:ok, second} =
             Migration.apply_packet(ctx.client, ctx.actor_id, packet,
               render_pdf: fn _ -> flunk("an idempotent retry must not render another PDF") end
             )

    assert [%{action: :reused}] = second.customers
    assert [%{action: :reused}, %{action: :reused}] = second.services
    assert [%{action: :reused, number: "57/2026-27"}] = second.quotations
    assert Repo.aggregate(from(i in Invoice, where: i.client_id == ^ctx.client.id), :count) == 1

    changed = put_in(packet, ["quotations", Access.at(0), "subject"], "Different work")

    assert {:ok, blocked} = Migration.preview(ctx.client, changed)
    refute blocked.ready?
    assert Enum.any?(blocked.errors, &String.contains?(&1, "existing number has different facts"))

    assert {:error, {:packet_not_ready, ^blocked}} =
             Migration.apply_packet(ctx.client, ctx.actor_id, changed)
  end

  test "unresolved source facts block every write", ctx do
    packet = put_in(packet()["unresolved"], [%{"field" => "unit", "message" => "Confirm NOS"}])

    assert {:ok, preview} = Migration.preview(ctx.client, packet)
    refute preview.ready?

    assert {:error, {:packet_not_ready, ^preview}} =
             Migration.apply_packet(ctx.client, ctx.actor_id, packet)

    assert Repo.aggregate(from(c in Customer, where: c.client_id == ^ctx.client.id), :count) == 0
    assert Repo.aggregate(from(i in Invoice, where: i.client_id == ^ctx.client.id), :count) == 0
  end

  test "apply requires an actor who can access the business", ctx do
    outsider = user_fixture()

    assert {:error, :actor_not_authorized} =
             Migration.apply_packet(ctx.client, outsider.id, packet())

    assert Repo.aggregate(from(c in Customer, where: c.client_id == ^ctx.client.id), :count) == 0
  end

  test "calculated totals must match the source controls", ctx do
    packet =
      put_in(
        packet(),
        ["quotations", Access.at(0), "expected_totals_paise", "total"],
        1
      )

    assert {:ok, preview} = Migration.preview(ctx.client, packet)
    refute preview.ready?
    assert Enum.any?(preview.errors, &String.contains?(&1, "calculated 3127000"))
  end

  defp packet do
    %{
      "version" => 1,
      "source" => %{"file" => "example.xlsx", "sheets" => ["57-2026-27"]},
      "unresolved" => [],
      "customers" => [
        %{
          "ref" => "siemens",
          "name" => "Siemens Healthcare Pvt Ltd",
          "address" => "Piroshah Nagar, Vikhroli East, Mumbai 400079",
          "state_code" => "29",
          "gstin" => "29AAVCS8021P1ZB",
          "primary_address_ref" => "siemens-mumbai",
          "addresses" => [
            %{
              "ref" => "siemens-pune",
              "label" => "PH Diagnostic Centre",
              "address" => "PH Diagnostic Centre\nHadapsar, Pune 411002",
              "state_code" => "29",
              "usage" => "shipping"
            }
          ]
        }
      ],
      "services" => [
        %{
          "ref" => "acs-coil",
          "description" => "MRI ACS COIL",
          "kind" => "goods",
          "sac" => "84159000",
          "unit" => "NOS",
          "unit_price" => "20500",
          "gst_rate" => "18"
        },
        %{
          "ref" => "air-cargo",
          "description" => "Air Cargo and Transportation Charges",
          "kind" => "service",
          "sac" => "996531",
          "unit" => "service",
          "unit_price" => "6000",
          "gst_rate" => "18"
        }
      ],
      "quotations" => [
        %{
          "source_ref" => "57-2026-27",
          "status" => "issued",
          "number" => "57/2026-27",
          "invoice_date" => "2026-09-28",
          "customer_ref" => "siemens",
          "billing_address_ref" => "siemens-mumbai",
          "shipping_address_ref" => "siemens-pune",
          "place_of_supply" => "29",
          "subject" => "Supply of ACS coil",
          "lines" => [
            %{"service_ref" => "acs-coil", "quantity" => "1"},
            %{"service_ref" => "air-cargo", "quantity" => "1"}
          ],
          "expected_totals_paise" => %{
            "taxable" => 2_650_000,
            "tax" => 477_000,
            "total" => 3_127_000
          }
        }
      ]
    }
  end
end
