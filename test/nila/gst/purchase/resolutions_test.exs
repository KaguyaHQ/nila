defmodule Nila.Gst.Purchase.ResolutionsTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Accounts.Scope
  alias Nila.Clients
  alias Nila.Gst.Filing.Signoffs
  alias Nila.Gst.Purchase.{Month, Months, Register, Resolutions}
  alias Nila.Gst.Purchase.Reconciliation, as: Recon
  alias Nila.Repo

  @period "2025-10"
  @gstin "33AAACS1234A1Z9"

  setup do
    %{user: user, org: org, membership: membership} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{
        org_id: org.id,
        name: "Breeze Tech",
        type: "company",
        gstin: @gstin
      })

    books = [books("books-1", "INV-1"), books("books-2", "INV-2")]
    recon = Recon.reconcile(books, [])
    rows = Register.rows(books, recon, %{})

    {:ok, month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: rows,
        recon: recon,
        summary: Register.summary(rows)
      })

    %{
      user: user,
      org: org,
      client: client,
      month: month,
      scope: %Scope{user: user, current_org: org, membership: membership}
    }
  end

  describe "get_by_period_with_client/3" do
    test "scopes by org and preloads the client", %{org: org, client: client, month: month} do
      assert {:ok, fetched} = Months.get_by_period_with_client(org.id, client.id, @period)
      assert fetched.id == month.id
      assert fetched.client.id == client.id
      refute match?(%Ecto.Association.NotLoaded{}, fetched.client)

      %{org: other_org} = user_with_org_fixture()

      assert {:error, :not_found} =
               Months.get_by_period_with_client(other_org.id, client.id, @period)
    end
  end

  describe "record_and_refresh/3" do
    test "atomically stores the event and refreshed projection", %{month: month, user: user} do
      attrs = %{
        "verb" => "accept_unmatched",
        "books_id" => "books-1",
        "payload" => %{"reason" => "await_2b"}
      }

      assert {:ok, result} = Resolutions.record_and_refresh(month, attrs, user.id)
      assert result.resolution.id == hd(result.resolutions).id
      assert result.resolution.verb == "accept_unmatched"
      assert result.month.client.id == month.client_id
      assert result.month.register_rows == result.workings.rows
      assert result.month.summary == result.workings.summary
      assert result.workings.summary["accepted_unmatched"] == 1

      assert [stored] = Resolutions.list(month.id)
      assert stored.id == result.resolution.id

      persisted = Repo.get!(Month, month.id)
      assert persisted.register_rows == json_roundtrip(result.workings.rows)
      assert persisted.summary == result.workings.summary
      assert persisted.recon == json_roundtrip(month.recon)
    end

    test "record/3 preserves its singleton return shape", %{month: month, user: user} do
      assert {:ok, resolution} =
               Resolutions.record(
                 month,
                 %{
                   "verb" => "accept_unmatched",
                   "books_id" => "books-1",
                   "payload" => %{"reason" => "not_claimable"}
                 },
                 user.id
               )

      assert resolution.verb == "accept_unmatched"
    end
  end

  describe "record_many_and_refresh/3" do
    test "stores the whole batch and refreshes the projection after all decisions", context do
      attrs_list =
        for id <- ["books-1", "books-2"] do
          %{
            "verb" => "accept_unmatched",
            "books_id" => id,
            "payload" => %{"reason" => "await_2b"}
          }
        end

      assert {:ok, result} =
               Resolutions.record_many_and_refresh(context.month, attrs_list, context.user.id)

      assert Enum.map(result.resolutions, & &1.books_id) == ["books-1", "books-2"]
      assert result.resolution.id == hd(result.resolutions).id
      assert result.workings.summary["accepted_unmatched"] == 2
      assert Register.need_decision(result.workings.summary) == 0
      assert length(Resolutions.list(context.month.id)) == 2

      persisted = Repo.get!(Month, context.month.id)
      assert persisted.register_rows == json_roundtrip(result.workings.rows)
      assert persisted.summary == result.workings.summary
    end

    test "rolls back every row and the projection when one insert is invalid", context do
      before = Repo.get!(Month, context.month.id)

      assert {:error, %Ecto.Changeset{}} =
               Resolutions.record_many_and_refresh(
                 context.month,
                 [
                   %{"verb" => "reopen", "books_id" => "books-1"},
                   %{"verb" => "not_a_verb", "books_id" => "books-2"}
                 ],
                 context.user.id
               )

      assert Resolutions.list(context.month.id) == []
      persisted = Repo.get!(Month, context.month.id)
      assert persisted.register_rows == before.register_rows
      assert persisted.summary == before.summary
    end
  end

  test "a live purchase signoff rejects new decisions", context do
    assert {:ok, _signoff} = Signoffs.sign_off(context.month, context.scope)

    assert {:error, :signed_off} =
             Resolutions.record_and_refresh(
               context.month,
               %{"verb" => "reopen", "books_id" => "books-1"},
               context.user.id
             )

    assert Resolutions.list(context.month.id) == []
  end

  defp json_roundtrip(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp books(id, invoice_number) do
    %{
      "id" => id,
      "vendor_name" => "Sharma Steels",
      "vendor_gstin" => @gstin,
      "invoice_number" => invoice_number,
      "invoice_date" => "2025-10-05",
      "taxable_paise" => 100_000,
      "tax_paise" => %{"cgst" => 9_000, "sgst" => 9_000, "igst" => 0},
      "total_paise" => 118_000,
      "images" => [],
      "pages" => [1]
    }
  end
end
