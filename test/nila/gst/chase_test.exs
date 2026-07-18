defmodule Nila.Gst.ChaseTest do
  use Nila.DataCase, async: true

  import Nila.AccountsFixtures

  alias Nila.Clients
  alias Nila.Gst.{Chase, ClientMonths, SalesMonths}

  @period "2025-10"

  setup do
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Clients.create_client(%{org_id: org.id, name: "Breeze Tech", type: "company"})

    %{user: user, org: org, client: client}
  end

  defp recon_with_2b_gap do
    %{
      "matched" => [],
      "value_mismatch" => [],
      "needs_human" => [],
      "in_books_not_2b" => [],
      "in_2b_not_books" => [
        %{
          "gstr2b" => %{
            "vendor_name" => "Sharma Steels",
            "vendor_gstin" => "33AAACS1234A1Z9",
            "invoice_number" => "INV-042",
            "invoice_date" => "2025-10-12",
            "taxable_paise" => 1_000_000,
            "tax_paise" => %{"cgst" => 90_000, "sgst" => 90_000, "igst" => 0},
            "total_paise" => 1_180_000
          }
        }
      ]
    }
  end

  defp seed_client_month(org, client, recon) do
    {:ok, month} =
      ClientMonths.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        recon: recon,
        summary: %{}
      })

    month
  end

  describe "slots/3" do
    test "reflects which aggregates exist", %{org: org, client: client} do
      assert Chase.slots(org.id, client.id, @period) == %{purchase: false, sales: false}

      seed_client_month(org, client, recon_with_2b_gap())
      assert Chase.slots(org.id, client.id, @period) == %{purchase: true, sales: false}

      {:ok, _} =
        SalesMonths.upsert(%{
          org_id: org.id,
          client_id: client.id,
          period: @period,
          state: "worked"
        })

      assert Chase.slots(org.id, client.id, @period) == %{purchase: true, sales: true}
    end
  end

  describe "gaps/1" do
    test "surfaces the effective 2B-only entries and sales sequence issues", %{
      org: org,
      client: client
    } do
      month = seed_client_month(org, client, recon_with_2b_gap())

      {:ok, _} =
        SalesMonths.upsert(%{
          org_id: org.id,
          client_id: client.id,
          period: @period,
          state: "worked",
          issues: [
            %{
              "code" => "sequence_gaps",
              "message" =>
                "missing/cancelled inferred from sequence: 7 — confirm cancellation records"
            },
            %{"code" => "grand_total_mismatch", "message" => "irrelevant here"}
          ]
        })

      gaps = Chase.gaps(month)

      assert [entry] = gaps.in_2b_not_books
      assert entry["gstr2b"]["vendor_name"] == "Sharma Steels"
      assert [%{"code" => "sequence_gaps"}] = gaps.sequence_issues
    end
  end

  describe "draft/4 :month_open" do
    test "names the client, the month, the due date, and signs as the firm", %{
      org: org,
      client: client
    } do
      text = Chase.draft(:month_open, org, client, @period)

      assert text =~ "Dear Breeze Tech"
      assert text =~ "GST filing for October 2025 is open"
      assert text =~ "sales invoices and purchase bills"
      assert text =~ "GSTR-1 is due 11 Nov 2025"
      assert text =~ "Regards,\n#{org.name}"
    end
  end

  describe "draft/5 :missing_bills" do
    test "lists each 2B-only bill with vendor, number, and amount", %{
      org: org,
      client: client
    } do
      month = seed_client_month(org, client, recon_with_2b_gap())
      text = Chase.draft(:missing_bills, org, client, @period, Chase.gaps(month))

      assert text =~ "Dear Breeze Tech"
      assert text =~ "• Sharma Steels — invoice INV-042, ₹11,800.00"
      assert text =~ "GSTR-3B for October 2025 is due 20 Nov 2025"
      assert text =~ "Regards,\n#{org.name}"
      refute text =~ "invoice numbering"
    end

    test "relays sequence gaps when the sales month reports them", %{
      org: org,
      client: client
    } do
      month = seed_client_month(org, client, recon_with_2b_gap())

      {:ok, _} =
        SalesMonths.upsert(%{
          org_id: org.id,
          client_id: client.id,
          period: @period,
          state: "worked",
          issues: [
            %{
              "code" => "sequence_gaps",
              "message" =>
                "missing/cancelled inferred from sequence: 7 — confirm cancellation records"
            }
          ]
        })

      text = Chase.draft(:missing_bills, org, client, @period, Chase.gaps(month))

      assert text =~ "gaps in your own invoice numbering"
      assert text =~ "missing/cancelled inferred from sequence: 7"
    end
  end

  describe "record_ask/2 + last_ask/3 + list_asks/3" do
    test "logs append-only and returns the newest first", %{
      user: user,
      org: org,
      client: client
    } do
      scope_ids = %{org_id: org.id, client_id: client.id, sent_by_id: user.id}

      assert {:error, :not_found} = Chase.last_ask(org.id, client.id, @period)

      {:ok, first} =
        Chase.record_ask(scope_ids, %{kind: "month_open", period: @period, body: "first ask"})

      {:ok, second} =
        Chase.record_ask(scope_ids, %{kind: "missing_bills", period: @period, body: "second ask"})

      assert first.sent_by_id == user.id
      assert {:ok, latest} = Chase.last_ask(org.id, client.id, @period)
      assert latest.id == second.id

      assert [second.id, first.id] ==
               Chase.list_asks(org.id, client.id, @period) |> Enum.map(& &1.id)
    end

    test "rejects an unknown kind", %{user: user, org: org, client: client} do
      assert {:error, changeset} =
               Chase.record_ask(
                 %{org_id: org.id, client_id: client.id, sent_by_id: user.id},
                 %{kind: "carrier_pigeon", period: @period, body: "x"}
               )

      assert %{kind: ["is invalid"]} = errors_on(changeset)
    end

    test "another org's asks are invisible", %{user: user, org: org, client: client} do
      %{org: other_org} = user_with_org_fixture()

      {:ok, _} =
        Chase.record_ask(
          %{org_id: org.id, client_id: client.id, sent_by_id: user.id},
          %{kind: "month_open", period: @period, body: "ask"}
        )

      assert {:error, :not_found} = Chase.last_ask(other_org.id, client.id, @period)
    end
  end
end
