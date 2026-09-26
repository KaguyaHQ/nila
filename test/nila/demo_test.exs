defmodule Nila.DemoTest do
  use Nila.DataCase, async: false
  import Nila.AccountsFixtures
  alias Nila.{Accounts, Clients, Demo}
  alias Nila.Accounts.Scope
  alias Nila.Gst.Intake.Dumps
  alias Nila.Gst.Sales.Months

  setup do
    %{org: org, user: user} = user_with_org_fixture()
    {:ok, org} = Demo.designate(org.id)
    %{org: org, user: user, scope: Scope.for_user(user)}
  end

  test "resets arbitrary clients and months, preserves identities and another firm's data, and repeats",
       ctx do
    first = client(ctx.org)
    second = client(ctx.org)
    other = user_with_org_fixture()
    untouched = client(other.org)
    token = Accounts.generate_user_session_token(ctx.user)
    {:ok, month} = Months.upsert(%{org_id: ctx.org.id, client_id: first.id, period: "2025-07"})
    Repo.update!(Ecto.Changeset.change(month, state: "filed"))
    {:ok, _} = Months.upsert(%{org_id: ctx.org.id, client_id: second.id, period: "2026-09"})

    {:ok, dump} =
      Dumps.record(%{org_id: ctx.org.id, client_id: first.id}, %{
        period: "2026-09",
        kind: "sales",
        status: "extracted",
        file_keys: []
      })

    {:ok, job} = %{dump_id: dump.id} |> Nila.Gst.Intake.DumpWorker.new() |> Oban.insert()

    {:ok, other_job} =
      %{org_id: other.org.id, client_id: untouched.id}
      |> Nila.Notices.SyncWorker.new()
      |> Oban.insert()

    business = user_fixture()
    Repo.insert!(%Nila.Business.ClientAccess{user_id: business.id, client_id: second.id})

    {:ok, customer} =
      Nila.Business.Invoicing.create_customer(second, %{
        name: "Customer",
        address: "Chennai",
        state_code: "33"
      })

    {:ok, invoice} =
      Nila.Business.Invoicing.save_draft(second, business.id, %{
        "customer_id" => customer.id,
        "invoice_date" => "2026-09-26",
        "place_of_supply" => "33",
        "lines" => [
          %{
            "description" => "Item",
            "sac" => "998312",
            "quantity" => "1",
            "unit" => "unit",
            "unit_price" => "100",
            "gst_rate" => "18"
          }
        ]
      })

    # A quote/invoice chain exercises restrictive self-references during reset.
    {:ok, revision} =
      Nila.Business.Invoicing.save_draft(second, business.id, %{
        "customer_id" => customer.id,
        "invoice_date" => "2026-09-26",
        "place_of_supply" => "33",
        "lines" => [
          %{
            "description" => "Revision",
            "sac" => "998312",
            "quantity" => "1",
            "unit" => "unit",
            "unit_price" => "100",
            "gst_rate" => "18"
          }
        ]
      })

    Repo.update_all(from(i in Nila.Business.Invoice, where: i.id == ^revision.id),
      set: [revised_from_id: invoice.id]
    )

    assert {:ok, %{clients_removed: 2}} = Demo.reset(ctx.scope)
    assert Clients.list_clients(ctx.org.id) == []
    assert Repo.get(Oban.Job, job.id) == nil
    assert Repo.get(Oban.Job, other_job.id)
    assert Repo.get(Clients.Client, untouched.id)
    assert Repo.get(Nila.Business.Invoice, invoice.id) == nil
    assert Nila.Business.Access.client_for_user(business.id) == nil
    assert Accounts.get_user_by_session_token(token).id == ctx.user.id
    assert Scope.for_user(ctx.user).current_org.id == ctx.org.id
    assert Repo.get(Nila.Accounts.User, business.id)
    assert {:ok, %{clients_removed: 0}} = Demo.reset(ctx.scope)
    assert client(ctx.org)
  end

  test "checks current database designation and ownership, not email or stale scope", ctx do
    assert Demo.available?(ctx.scope)
    Repo.update_all(from(o in Nila.Orgs.Org, where: o.id == ^ctx.org.id), set: [is_demo: false])
    assert {:error, :forbidden} = Demo.reset(ctx.scope)
    {:ok, _} = Demo.designate(ctx.org.id)

    Repo.update_all(from(m in Nila.Orgs.Membership, where: m.user_id == ^ctx.user.id),
      set: [role: "admin"]
    )

    assert {:error, :forbidden} = Demo.reset(ctx.scope)
    assert {:error, :forbidden} = Demo.reset(nil)
    refute Map.has_key?(Nila.Orgs.Org.changeset(ctx.org, %{is_demo: true}).changes, :is_demo)
  end

  test "refuses a running job without clearing anything; queued jobs can be removed", ctx do
    client = client(ctx.org)

    {:ok, job} =
      %{org_id: ctx.org.id, client_id: client.id}
      |> Nila.Notices.SyncWorker.new()
      |> Oban.insert()

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "executing"])
    assert {:error, :processing} = Demo.reset(ctx.scope)
    assert Repo.get(Clients.Client, client.id)
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "retryable"])
    assert {:ok, _} = Demo.reset(ctx.scope)
  end

  test "quick login exposes workspace roles, excluding inactive users and ordinary firms", ctx do
    client = client(ctx.org)
    business = user_fixture()
    Repo.insert!(%Nila.Business.ClientAccess{user_id: business.id, client_id: client.id})
    user_with_org_fixture()

    assert Nila.Development.quick_login_users() == [
             %{name: "Firm workspace", email: ctx.user.email},
             %{name: "Business workspace", email: business.email}
           ]

    Accounts.update_user(business, %{active: false})

    assert Nila.Development.quick_login_users() == [
             %{name: "Firm workspace", email: ctx.user.email}
           ]
  end

  test "the development rebuild refuses the test environment" do
    assert_raise Mix.Error, ~r/only resets the local nila_dev/, fn ->
      Mix.Tasks.Nila.Dev.Reset.run([])
    end
  end

  test "clears purchase decisions, allocations and signed months in dependency order", ctx do
    alias Nila.Gst.Purchase.{
      Month,
      ItcCase,
      ItcSource,
      ItcCaseEvent,
      ItcSourceCaseEvent,
      ItcAllocation
    }

    c = client(ctx.org)

    month =
      Repo.insert!(%Month{org_id: ctx.org.id, client_id: c.id, period: "2026-08", state: "filed"})

    item = Repo.insert!(%ItcCase{org_id: ctx.org.id, client_id: c.id})

    source =
      Repo.insert!(%ItcSource{
        org_id: ctx.org.id,
        client_month_id: month.id,
        kind: "books",
        source_ref: "example",
        payload: %{}
      })

    Repo.insert!(%ItcCaseEvent{
      org_id: ctx.org.id,
      case_id: item.id,
      effective_client_month_id: month.id,
      event_type: "documents_requested"
    })

    Repo.insert!(%ItcSourceCaseEvent{
      org_id: ctx.org.id,
      case_id: item.id,
      source_id: source.id,
      effective_client_month_id: month.id,
      action: "linked",
      reason: "example"
    })

    signoff =
      Repo.insert!(%Nila.Gst.Filing.Signoff{
        org_id: ctx.org.id,
        client_month_id: month.id,
        signed_by_id: ctx.user.id,
        snapshot: %{}
      })

    Repo.insert!(%ItcAllocation{
      org_id: ctx.org.id,
      case_id: item.id,
      client_month_id: month.id,
      signoff_id: signoff.id,
      tax_heads: %{"igst" => 100},
      tax_paise: 100
    })

    assert {:ok, _} = Demo.reset(ctx.scope)
    refute Repo.get(Month, month.id)
    refute Repo.get(ItcCase, item.id)
    refute Repo.get(ItcSource, source.id)
    refute Repo.get(Nila.Gst.Filing.Signoff, signoff.id)
  end

  defp client(org),
    do:
      elem(
        Clients.create_client(%{
          org_id: org.id,
          name: "Any client #{System.unique_integer([:positive])}",
          type: "company",
          chase_channel: "none"
        }),
        1
      )
end
