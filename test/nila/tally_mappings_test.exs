defmodule Nila.TallyMappingsTest do
  use Nila.DataCase, async: true

  alias Nila.Orgs.Org
  alias Nila.Repo
  alias Nila.TallyDevices
  alias Nila.TallyDevices.SyncedMaster
  alias Nila.TallyMappings

  test "resolves a unique exact GSTIN before names" do
    org = org_fixture()
    company = company_fixture(org, "Nila")
    target = ledger_fixture(org.id, company.id, "customer-ap", "Customer AP", "29AAVCS8021P1ZB")
    _same_name = ledger_fixture(org.id, company.id, "same-name", "Invoice Customer", nil)

    assert {:ok, %{ledger: ^target, matched_by: :gstin}} =
             TallyMappings.resolve_party(org.id, company.id, %{
               gstin: "29aavcs8021p1zb",
               name: "Invoice Customer"
             })
  end

  test "uses a confirmed choice to disambiguate duplicate GSTIN ledgers" do
    org = org_fixture()
    company = company_fixture(org, "Nila")
    _first = ledger_fixture(org.id, company.id, "customer-1", "Customer One", "29AAVCS8021P1ZB")
    selected = ledger_fixture(org.id, company.id, "customer-2", "Customer Two", "29AAVCS8021P1ZB")
    identity = %{gstin: "29AAVCS8021P1ZB", name: "Customer"}

    assert {:error, {:ambiguous, [_, _]}} =
             TallyMappings.resolve_party(org.id, company.id, identity)

    assert {:ok, mapping} =
             TallyMappings.save_confirmed_party_choice(
               org.id,
               company.id,
               identity,
               selected.identity
             )

    assert mapping.ledger_identity == selected.identity
    assert mapping.confirmation_source == "manual"
    assert mapping.confirmed_at

    assert {:ok, %{ledger: ^selected, matched_by: :saved}} =
             TallyMappings.resolve_party(org.id, company.id, identity)
  end

  test "a confirmed choice overrides an otherwise unique GSTIN match" do
    org = org_fixture()
    company = company_fixture(org, "Nila")

    _automatic =
      ledger_fixture(org.id, company.id, "gstin-ledger", "GSTIN Ledger", "29AAVCS8021P1ZB")

    selected = ledger_fixture(org.id, company.id, "selected-ledger", "Selected Ledger", nil)
    identity = %{gstin: "29AAVCS8021P1ZB", name: "Customer"}

    assert {:ok, _mapping} =
             TallyMappings.save_confirmed_party_choice(
               org.id,
               company.id,
               identity,
               selected.identity
             )

    assert {:ok, %{ledger: ^selected, matched_by: :saved}} =
             TallyMappings.resolve_party(org.id, company.id, identity)
  end

  test "normalizes an exact name but reports duplicate names as ambiguous" do
    org = org_fixture()
    company = company_fixture(org, "Nila")

    target =
      ledger_fixture(org.id, company.id, "siemens-ap", "Siemens Healthcare Pvt. Ltd - AP", nil)

    assert {:ok, %{ledger: ^target, matched_by: :name}} =
             TallyMappings.resolve_party(org.id, company.id, %{
               name: "  SIEMENS HEALTHCARE PVT LTD--AP "
             })

    _duplicate =
      ledger_fixture(org.id, company.id, "siemens-ap-2", "SIEMENS HEALTHCARE PVT LTD AP", nil)

    assert {:error, {:ambiguous, [_, _]}} =
             TallyMappings.resolve_party(org.id, company.id, %{
               name: "Siemens Healthcare Pvt Ltd AP"
             })
  end

  test "ledger choices and saved mappings cannot cross company or organisation scope" do
    org = org_fixture()
    other_org = org_fixture()
    company = company_fixture(org, "Nila")
    other_company = company_fixture(other_org, "Other")
    local = ledger_fixture(org.id, company.id, "local", "Local", nil)
    foreign = ledger_fixture(other_org.id, other_company.id, "foreign", "Foreign", nil)

    assert TallyMappings.list_ledger_choices(org.id, company.id) == [local]

    assert {:error, :ledger_not_found} =
             TallyMappings.save_confirmed_party_choice(
               org.id,
               company.id,
               %{source_key: "invoice-customer"},
               foreign.identity
             )
  end

  test "creates and replaces posting defaults only with synced ledgers from the company" do
    org = org_fixture()
    company = company_fixture(org, "Nila")
    other_company = company_fixture(org, "Other")
    sales = ledger_fixture(org.id, company.id, "sales", "Material Sales", nil)
    igst = ledger_fixture(org.id, company.id, "igst", "Output IGST", nil)
    foreign = ledger_fixture(org.id, other_company.id, "foreign", "Foreign Sales", nil)

    assert {:error, :not_found} = TallyMappings.get_posting_profile(org.id, company.id)

    assert {:ok, profile} =
             TallyMappings.save_posting_profile(org.id, company.id, %{
               "sales_ledger_identity" => sales.identity,
               "igst_ledger_identity" => igst.identity
             })

    assert profile.sales_ledger_identity == sales.identity
    assert profile.igst_ledger_identity == igst.identity

    assert {:error, :ledger_not_found} =
             TallyMappings.save_posting_profile(org.id, company.id, %{
               sales_ledger_identity: foreign.identity
             })

    assert {:ok, unchanged} = TallyMappings.get_posting_profile(org.id, company.id)
    assert unchanged.sales_ledger_identity == sales.identity
    assert unchanged.igst_ledger_identity == igst.identity

    assert {:ok, updated} =
             TallyMappings.save_posting_profile(org.id, company.id, %{
               sales_ledger_identity: igst.identity
             })

    assert updated.sales_ledger_identity == igst.identity
    assert updated.igst_ledger_identity == igst.identity
  end

  test "resolves an unambiguous GST ledger from its structured duty head" do
    org = org_fixture()
    company = company_fixture(org, "Nila")

    target =
      ledger_fixture(org.id, company.id, "central-tax", "Tax payable", nil,
        tax_type: "GST",
        gst_duty_head: "Central Tax"
      )

    _other =
      ledger_fixture(org.id, company.id, "integrated-tax", "Another tax", nil,
        tax_type: "GST",
        gst_duty_head: "Integrated Tax"
      )

    assert {:ok, %{ledger: ^target, matched_by: :gst_duty_head}} =
             TallyMappings.resolve_tax_ledger(org.id, company.id, :cgst)
  end

  test "does not guess a GST duty head from the ledger name" do
    org = org_fixture()
    company = company_fixture(org, "Nila")
    _named = ledger_fixture(org.id, company.id, "output-igst", "Output IGST", nil)

    assert {:error, :not_found} = TallyMappings.resolve_tax_ledger(org.id, company.id, :igst)
  end

  test "leaves duplicate structured GST duty heads ambiguous" do
    org = org_fixture()
    company = company_fixture(org, "Nila")

    for identity <- ~w(first second) do
      ledger_fixture(org.id, company.id, identity, "#{identity} output", nil,
        tax_type: "GST",
        gst_duty_head: "IGST"
      )
    end

    assert {:error, {:ambiguous, matches}} =
             TallyMappings.resolve_tax_ledger(org.id, company.id, "Integrated Tax")

    assert length(matches) == 2
  end

  test "saves a confirmed party and posting defaults atomically" do
    org = org_fixture()
    company = company_fixture(org, "Nila")
    party = ledger_fixture(org.id, company.id, "party", "Customer", nil)
    sales = ledger_fixture(org.id, company.id, "sales", "Sales", nil)

    assert {:ok, %{party_mapping: mapping, posting_profile: profile}} =
             TallyMappings.save_sales_posting(
               org.id,
               company.id,
               %{name: "Invoice Customer"},
               party.identity,
               %{sales_ledger_identity: sales.identity}
             )

    assert mapping.ledger_identity == party.identity
    assert profile.sales_ledger_identity == sales.identity

    assert {:error, :ledger_not_found} =
             TallyMappings.save_sales_posting(
               org.id,
               company.id,
               %{name: "Rolled Back Customer"},
               party.identity,
               %{sales_ledger_identity: "missing"}
             )

    assert {:error, :not_found} =
             TallyMappings.resolve_party(org.id, company.id, %{name: "Rolled Back Customer"})
  end

  test "remembers a Sales Accounts ledger by normalized HSN and item description" do
    org = org_fixture()
    company = company_fixture(org, "Nila")
    sales = sales_ledger_fixture(org.id, company.id, "material-sales", "Material Sales")
    line = %{hsn_sac: "8415-90-00", item_name: "Condenser Coil 7.5TR Chiller"}

    assert [^sales] = TallyMappings.list_sales_ledger_choices(org.id, company.id)

    assert {:ok, mapping} =
             TallyMappings.save_sales_ledger_choice(org.id, company.id, line, sales.identity)

    assert mapping.hsn_sac == "84159000"
    assert mapping.normalized_description == "condenser coil 7 5tr chiller"

    assert {:ok, %{ledger: ^sales, matched_by: :saved}} =
             TallyMappings.resolve_sales_ledger(org.id, company.id, %{
               "hsn_sac" => 84_159_000,
               "item_name" => "",
               "description" => "  CONDENSER COIL 7.5TR--CHILLER "
             })

    assert {:error, :not_found} =
             TallyMappings.resolve_sales_ledger(org.id, company.id, %{
               hsn_sac: "84159001",
               item_name: "Condenser Coil 7.5TR Chiller"
             })
  end

  test "rejects non-Sales Accounts and cross-company ledgers for line mappings" do
    org = org_fixture()
    company = company_fixture(org, "Nila")
    other_company = company_fixture(org, "Other")
    tax = ledger_fixture(org.id, company.id, "output-igst", "Output IGST", nil)

    foreign_sales =
      sales_ledger_fixture(org.id, other_company.id, "foreign-sales", "Foreign Sales")

    line = %{hsn_sac: "998719", description: "Courier charges"}

    assert {:error, :sales_ledger_not_found} =
             TallyMappings.save_sales_ledger_choice(org.id, company.id, line, tax.identity)

    assert {:error, :sales_ledger_not_found} =
             TallyMappings.save_sales_ledger_choice(
               org.id,
               company.id,
               line,
               foreign_sales.identity
             )
  end

  defp company_fixture(org, name) do
    {:ok, device, _token} = TallyDevices.create_device(org, %{name: "#{name} Accounts PC"})
    {:ok, [company]} = TallyDevices.report_companies(device, [%{"name" => name}])
    company
  end

  defp org_fixture do
    %Org{}
    |> Org.changeset(%{name: "Org #{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp ledger_fixture(org_id, company_id, identity, name, gstin, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    data =
      opts
      |> Enum.into(%{}, fn {key, value} -> {Atom.to_string(key), value} end)
      |> then(&if(gstin, do: Map.put(&1, "gstin", gstin), else: &1))

    %SyncedMaster{
      org_id: org_id,
      company_id: company_id,
      kind: "ledger",
      identity: identity,
      name: name,
      data: data,
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end

  defp sales_ledger_fixture(org_id, company_id, identity, name) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %SyncedMaster{
      org_id: org_id,
      company_id: company_id,
      kind: "ledger",
      identity: identity,
      name: name,
      data: %{"parent" => "Sales Accounts"},
      inserted_at: now,
      updated_at: now
    }
    |> Repo.insert!()
  end
end
