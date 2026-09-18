defmodule Nila.Gst.PortalTest do
  use Nila.DataCase, async: false
  use Oban.Testing, repo: Nila.Repo
  import Nila.AccountsFixtures
  alias Nila.Gst.Portal
  alias Nila.Gst.Portal.{TaxpayerLookup, TaxpayerWorker}
  alias Nila.Gst.Sales.{TaxpayerChecks, SourcePacket}
  alias Nila.Integrations.Whitebooks
  alias Nila.Repo

  @gstin "33AEWPH4158J1Z3"

  setup do
    previous = Application.get_env(:nila, Whitebooks)

    Application.put_env(:nila, Whitebooks,
      client_id: "test",
      client_secret: "secret",
      email: "test@example.test",
      req_options: [plug: {Req.Test, Whitebooks}]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nila, Whitebooks, previous),
        else: Application.delete_env(:nila, Whitebooks)
    end)

    :ok
  end

  defp response(overrides \\ %{}) do
    %{
      "status_cd" => "1",
      "data" =>
        Map.merge(
          %{
            "gstin" => @gstin,
            "lgnm" => "Breeze Technologies Private Limited",
            "tradeNam" => "Breeze Tech",
            "sts" => "Active"
          },
          overrides
        )
    }
  end

  defp expect_lookup(response) do
    Req.Test.expect(Whitebooks, fn conn ->
      assert conn.request_path == "/public/search"
      assert Plug.Conn.get_req_header(conn, "gst_username") == []
      Req.Test.json(conn, response)
    end)
  end

  test "one saved GSTIN is reused without a session; only successful refresh replaces it" do
    expect_lookup(response())
    assert {:ok, first} = Portal.lookup_taxpayer(" 33aewph4158j1z3 ")
    assert first.trade_name == "Breeze Tech"
    assert {:ok, cached} = Portal.lookup_taxpayer(@gstin)
    assert cached.id == first.id
    assert cached.checked_at == first.checked_at

    within_month =
      first
      |> Ecto.Changeset.change(checked_at: DateTime.add(first.checked_at, -29, :day))
      |> Repo.update!()

    assert {:ok, cached} = Portal.lookup_taxpayer(@gstin)
    assert cached.checked_at == within_month.checked_at

    stale =
      first
      |> Ecto.Changeset.change(checked_at: DateTime.add(first.checked_at, -30, :day))
      |> Repo.update!()

    expect_lookup(%{"status_cd" => "0", "error" => %{"errorCode" => "WB_ERR_9101"}})
    assert {:error, {:provider, "WB_ERR_9101"}} = Portal.lookup_taxpayer(@gstin)
    assert Repo.get!(TaxpayerLookup, first.id).checked_at == stale.checked_at
    expect_lookup(response(%{"sts" => "Suspended"}))
    assert {:ok, refreshed} = Portal.lookup_taxpayer(@gstin)
    assert refreshed.id == first.id
    assert refreshed.registration_status == "Suspended"
    assert Repo.aggregate(TaxpayerLookup, :count) == 1
  end

  test "bad checksum, mismatched GSTIN and incomplete response cannot create a success" do
    assert {:error, :invalid_gstin} = Portal.lookup_taxpayer("33AEWPH4158J1Z0")

    for data <- [%{"gstin" => "33CPWPV2650A1ZQ"}, %{"lgnm" => ""}, %{"sts" => nil}] do
      expect_lookup(response(data))
      assert {:error, :unexpected_response} = Portal.lookup_taxpayer(@gstin)
    end

    assert Repo.aggregate(TaxpayerLookup, :count) == 0
  end

  test "only taxpayer fields are retained, never authentication or echoed secrets" do
    expect_lookup(
      response(%{"client_secret" => "private", "txn" => "session", "otp" => "123456"})
    )

    assert {:ok, saved} = Portal.lookup_taxpayer(@gstin)
    refute inspect(saved.payload) =~ "private"
    refute Map.has_key?(saved.payload, "txn")
    refute Map.has_key?(saved.payload, "otp")
  end

  test "batch lookups deduplicate GSTINs and failures remain job errors" do
    %{org: org} = user_with_org_fixture()
    invoice = %{"buyer_gstin" => @gstin, "seller_gstin" => @gstin}
    assert :ok = TaxpayerChecks.enqueue(org.id, [invoice, invoice])
    assert :ok = TaxpayerChecks.enqueue(org.id, [invoice])
    assert [%{args: %{"gstin" => @gstin}}] = all_enqueued(worker: TaxpayerWorker)
    Req.Test.expect(Whitebooks, fn conn -> Req.Test.transport_error(conn, :timeout) end)
    assert {:error, :unavailable} = perform_job(TaxpayerWorker, %{org_id: org.id, gstin: @gstin})
    assert Repo.aggregate(TaxpayerLookup, :count) == 0

    Nila.Gst.Intake.Progress.subscribe(org.id)
    expect_lookup(response())
    assert :ok = perform_job(TaxpayerWorker, %{org_id: org.id, gstin: @gstin})
    assert_receive {:gst_taxpayer_checked, @gstin}
  end

  test "public cache feeds sales checks without changing invoice facts" do
    expect_lookup(response())
    {:ok, _} = Portal.lookup_taxpayer(@gstin)

    invoice = %{
      "id" => "source-1",
      "invoice_number" => "INV-1",
      "buyer_gstin" => @gstin,
      "buyer_name" => "Breeze Tech",
      "seller_gstin" => nil,
      "line_items" => []
    }

    [checked] = TaxpayerChecks.annotate([invoice], %{taxpayers: TaxpayerChecks.saved([invoice])})
    assert checked["buyer_name"] == invoice["buyer_name"]
    assert checked["buyer_gstin"] == invoice["buyer_gstin"]
    assert TaxpayerChecks.issues([checked]) == []

    assert Enum.find(TaxpayerChecks.outcomes(checked), &(&1.id == "buyer_gst_name_review")).status ==
             :passed

    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Client",
        type: "company",
        gstin: @gstin
      })

    {:ok, dump} =
      Nila.Gst.Intake.Dumps.record(
        %{org_id: org.id, client_id: client.id},
        %{period: "2026-07", kind: "sales", status: "extracted", invoices: [invoice]}
      )

    assert [
             %{
               "taxpayer_checks" => %{
                 "buyer" => %{"legal_name" => "Breeze Technologies Private Limited"}
               }
             }
           ] =
             SourcePacket.prepare([dump]).invoices
  end

  test "a new taxpayer exception reopens reviewed months but preserves filed snapshots" do
    %{org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Client",
        type: "company",
        gstin: @gstin
      })

    invoice = %{
      "id" => "source-1",
      "invoice_number" => "INV-1",
      "buyer_gstin" => @gstin,
      "buyer_name" => "Another Business",
      "line_items" => []
    }

    {:ok, month} =
      Nila.Gst.Sales.Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-07",
        invoices: [invoice],
        state: "reviewed"
      })

    {:ok, filed} =
      Nila.Gst.Sales.Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: "2026-06",
        invoices: [invoice],
        state: "filed"
      })

    filed |> Ecto.Changeset.change(filed_at: DateTime.utc_now()) |> Repo.update!()
    expect_lookup(response())
    assert :ok = perform_job(TaxpayerWorker, %{org_id: org.id, gstin: @gstin})
    assert Repo.reload!(month).state == "worked"
    assert Repo.reload!(filed).state == "filed"
    assert Repo.reload!(filed).invoices == [invoice]
  end

  test "OTP challenges are bound to the requesting organization" do
    %{user: user} = user_with_org_fixture()
    scope = Nila.Accounts.Scope.for_user(user)

    challenge = %Portal.Challenge{
      org_id: -1,
      client_id: -1,
      requested_at: DateTime.utc_now(),
      account: %{}
    }

    assert {:error, :invalid_connection} = Portal.verify_otp(scope, challenge, "123456")
  end
end
