defmodule Nila.Gst.SignoffsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.{ClientMonths, Recon, Register, Signoffs}

  @period "2025-10"
  @gstin "33AAACS1234A1Z9"

  setup do
    %{user: owner, org: org, membership: owner_membership} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: @gstin
      })

    books = %{
      "id" => "page_01",
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => @gstin,
      "invoice_number" => "1134",
      "invoice_date" => ~D[2025-10-05],
      "taxable_paise" => 1_000_000,
      "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
      "total_paise" => 1_180_000,
      "images" => [],
      "pages" => [1]
    }

    recon = Recon.reconcile([books], [])
    rows = Register.rows([books], recon, %{})

    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    %{
      org: org,
      month: month,
      owner_scope: %Scope{user: owner, current_org: org, membership: owner_membership}
    }
  end

  test "owner signs off a worked month: state reviewed, frozen snapshot persisted", %{
    month: month,
    owner_scope: scope,
    org: org
  } do
    assert {:ok, signoff} = Signoffs.sign_off(month, scope)

    assert signoff.org_id == org.id
    assert signoff.client_month_id == month.id
    assert signoff.signed_by_id == scope.user.id

    for key <- ~w(summary itc gstr3b rows) do
      assert Map.has_key?(signoff.snapshot, key), "snapshot missing #{key}"
    end

    {:ok, month} = ClientMonths.get_by_period(month.org_id, month.client_id, month.period)
    assert month.state == "reviewed"

    assert {:ok, latest} = Signoffs.latest_signoff(month.id)
    assert latest.id == signoff.id
    assert latest.signed_by.id == scope.user.id
  end

  test "the operator (member) cannot self-certify", %{month: month, org: org} do
    member = user_fixture()
    {:ok, membership} = Nila.Orgs.add_user(org, member.id, "member")
    member_scope = %Scope{user: member, current_org: org, membership: membership}

    assert {:error, :not_allowed} = Signoffs.sign_off(month, member_scope)
    assert {:error, :not_found} = Signoffs.latest_signoff(month.id)

    {:ok, month} = ClientMonths.get_by_period(month.org_id, month.client_id, month.period)
    assert month.state == "worked"
  end

  test "signing an already-reviewed month errors", %{month: month, owner_scope: scope} do
    assert {:ok, _} = Signoffs.sign_off(month, scope)

    {:ok, reviewed} = ClientMonths.get_by_period(month.org_id, month.client_id, month.period)
    assert {:error, :already_signed} = Signoffs.sign_off(reviewed, scope)
  end
end
