defmodule Nila.Gst.Sales.Invoice.RemovalsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.Intake.Dumps

  alias Nila.Gst.Sales.{Batch, Month, SourcePacket}
  alias Nila.Gst.Sales.Invoice.Corrections, as: InvoiceCorrections
  alias Nila.Gst.Sales.Invoice.Removal, as: InvoiceRemoval
  alias Nila.Gst.Sales.Invoice.Removals, as: InvoiceRemovals

  setup do
    %{org: org, user: user} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Sales cleanup",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    invoice = %{
      "id" => "source-1",
      "invoice_number" => "INV-001",
      "invoice_date" => "2026-07-01",
      "buyer_name" => "Original customer",
      "line_items" => []
    }

    {:ok, dump} =
      Dumps.record(%{org_id: org.id, client_id: client.id}, %{
        period: "2026-07",
        kind: "sales",
        status: "extracted",
        invoices: [invoice]
      })

    month =
      Repo.insert!(%Month{
        org_id: org.id,
        client_id: client.id,
        period: "2026-07",
        invoices: [invoice],
        state: "reviewed"
      })

    %{
      org: org,
      user: user,
      client: client,
      invoice: invoice,
      dump: dump,
      month: month,
      ref: Batch.ref([dump])
    }
  end

  test "exclusion follows the source and can be restored from an expanded batch", c do
    {:ok, second} =
      Dumps.record(%{org_id: c.org.id, client_id: c.client.id}, %{
        period: "2026-07",
        kind: "sales",
        status: "extracted",
        invoices: [Map.put(c.invoice, "id", "source-2")]
      })

    expanded = [c.dump, second]

    assert {:ok, removal} =
             InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

    assert Repo.reload!(c.month).state == "worked"
    assert [%{"id" => "source-1"}] = SourcePacket.prepare(expanded).excluded
    assert InvoiceRemovals.active_sources(c.org.id, c.client.id, [c.invoice]) == []

    assert {:ok, repeated} =
             InvoiceRemovals.remove(
               c.org.id,
               c.client.id,
               Batch.ref(expanded),
               "source-1",
               c.user.id
             )

    assert repeated.id == removal.id
    assert Repo.aggregate(InvoiceRemoval, :count) == 1

    c.month |> Repo.reload!() |> Ecto.Changeset.change(state: "reviewed") |> Repo.update!()

    assert {:ok, :restored} =
             InvoiceRemovals.restore(
               c.org.id,
               c.client.id,
               Batch.ref(expanded),
               "source-1",
               c.user.id
             )

    assert Repo.reload!(c.month).state == "worked"
    assert SourcePacket.prepare([c.dump]).excluded == []
    assert Repo.reload!(c.dump).invoices == [c.invoice]
  end

  test "source changes invalidate only the affected review and preserve source evidence", c do
    untouched =
      Repo.insert!(%Month{
        org_id: c.org.id,
        client_id: c.client.id,
        period: "2026-06",
        invoices: [Map.put(c.invoice, "id", "other-source")],
        state: "reviewed"
      })

    assert {:ok, _} =
             InvoiceCorrections.save(
               c.org.id,
               c.client.id,
               c.ref,
               "source-1",
               %{buyer_name: "Corrected customer"},
               c.user.id
             )

    assert Repo.reload!(c.month).state == "worked"
    assert Repo.reload!(untouched).state == "reviewed"
    assert Repo.reload!(c.dump).invoices == [c.invoice]
  end

  test "unchanged or rejected corrections do not invalidate review", c do
    {purchase, signoff} = signed_purchase(c, false)

    assert {:ok, %{corrections: []}} =
             InvoiceCorrections.save(
               c.org.id,
               c.client.id,
               c.ref,
               "source-1",
               %{buyer_name: "Original customer"},
               c.user.id
             )

    assert Repo.reload!(c.month).state == "reviewed"
    assert Repo.reload!(signoff).revoked_at == nil
    assert Repo.reload!(purchase).state == "reviewed"

    assert {:error, _} =
             InvoiceCorrections.save(
               c.org.id,
               c.client.id,
               c.ref,
               "source-1",
               %{printed_grand_total: "not money"},
               c.user.id
             )

    assert Repo.reload!(c.month).state == "reviewed"
    assert Repo.reload!(signoff).revoked_at == nil
    assert Repo.reload!(purchase).state == "reviewed"
  end

  test "repeating an exclusion preserves the subsequently reviewed 3B", c do
    assert {:ok, original} =
             InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

    {purchase, signoff} = signed_purchase(c, false)
    c.month |> Repo.reload!() |> Ecto.Changeset.change(state: "reviewed") |> Repo.update!()

    assert {:ok, repeated} =
             InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

    assert repeated.id == original.id
    assert Repo.reload!(signoff).revoked_at == nil
    assert Repo.reload!(purchase).state == "reviewed"
    assert Repo.reload!(c.month).state == "reviewed"
  end

  test "filed sources cannot be corrected, excluded, or restored", c do
    assert {:ok, _} = InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

    c.month
    |> Ecto.Changeset.change(state: "filed", filed_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :filed} =
             InvoiceCorrections.save(
               c.org.id,
               c.client.id,
               c.ref,
               "source-1",
               %{buyer_name: "Changed after filing"},
               c.user.id
             )

    assert {:error, :filed} =
             InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

    assert {:error, :filed} =
             InvoiceRemovals.restore(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

    assert InvoiceCorrections.list(c.org.id, c.client.id, "source-1") == []
    assert Repo.aggregate(InvoiceRemoval, :count) == 1
    assert Repo.reload!(c.month).state == "filed"
  end

  for action <- [:correction, :exclusion, :restoration] do
    test "#{action} invalidates an unfiled 3B without blocking the sales edit", c do
      action = unquote(action)
      prepare_sales_change(c, action)
      {purchase, signoff} = signed_purchase(c, false)

      assert {:ok, _} = change_sales(c, action)
      assert Repo.reload!(signoff).revoked_at != nil
      assert Repo.reload!(purchase).state == "worked"
      assert Repo.reload!(c.month).state == "worked"
    end

    test "#{action} preserves an already filed 3B as history", c do
      action = unquote(action)
      prepare_sales_change(c, action)
      {purchase, signoff} = signed_purchase(c, true)

      assert {:ok, _} = change_sales(c, action)
      assert Repo.reload!(signoff).revoked_at == nil
      assert Repo.reload!(signoff).snapshot == signoff.snapshot
      assert Repo.reload!(purchase).state == "filed"
      assert Repo.reload!(purchase).filed_at == purchase.filed_at
      assert Repo.reload!(c.month).state == "worked"
    end
  end

  test "foreign actors and missing sources cannot exclude or restore", c do
    %{user: other_user} = user_with_org_fixture()

    assert {:error, :remover_not_in_org} =
             InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "source-1", other_user.id)

    assert {:error, :not_found} =
             InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "missing", c.user.id)

    assert {:error, :not_found} =
             InvoiceRemovals.restore(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

    assert Repo.reload!(c.month).state == "reviewed"
  end

  defp prepare_sales_change(c, :restoration) do
    assert {:ok, _} = InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "source-1", c.user.id)
  end

  defp prepare_sales_change(_c, _action), do: :ok

  defp change_sales(c, :correction),
    do:
      InvoiceCorrections.save(
        c.org.id,
        c.client.id,
        c.ref,
        "source-1",
        %{buyer_name: "Corrected customer"},
        c.user.id
      )

  defp change_sales(c, :exclusion),
    do: InvoiceRemovals.remove(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

  defp change_sales(c, :restoration),
    do: InvoiceRemovals.restore(c.org.id, c.client.id, c.ref, "source-1", c.user.id)

  defp signed_purchase(c, filed?) do
    purchase =
      Repo.insert!(%Nila.Gst.Purchase.Month{
        org_id: c.org.id,
        client_id: c.client.id,
        period: c.month.period,
        state: if(filed?, do: "filed", else: "reviewed"),
        filed_at: if(filed?, do: DateTime.utc_now())
      })

    signoff =
      Repo.insert!(%Nila.Gst.Filing.Signoff{
        org_id: c.org.id,
        client_month_id: purchase.id,
        signed_by_id: c.user.id,
        artifact: "gstr3b",
        snapshot: %{"gstr3b" => %{"liability_source" => "current_sales"}}
      })

    {purchase, signoff}
  end
end
