defmodule NilaWeb.Gst.ProgressiveSalesTest do
  use NilaWeb.ConnCase, async: false
  use Oban.Testing, repo: Nila.Repo
  import Phoenix.LiveViewTest
  import Nila.AccountsFixtures
  alias Nila.Gst.Intake.{Dumps, DumpWorker}
  alias Nila.Gst.Sales.{Batch, Months}

  setup %{conn: conn} do
    previous = Application.fetch_env!(:nila, :sales_extractor)
    Application.put_env(:nila, :sales_extractor, Nila.Gst.Extraction.Sales.ProgressiveStub)
    on_exit(fn -> Application.put_env(:nila, :sales_extractor, previous) end)
    %{user: user, org: org} = user_with_org_fixture()

    {:ok, client} =
      Nila.Clients.create_client(%{
        org_id: org.id,
        name: "Progressive",
        type: "company",
        gstin: "33AEWPH4158J1Z3"
      })

    key = "test/progressive/#{org.id}.pdf"
    {:ok, _} = Nila.Storage.put(key, :erlang.term_to_binary(self()))

    {:ok, dump} =
      Dumps.record(
        %{org_id: org.id, client_id: client.id, brought_in_by_id: user.id},
        %{period: "2025-10", kind: "sales", file_keys: [key], meta: %{"sales_batch" => true}}
      )

    %{conn: log_in_user(conn, user), user: user, org: org, client: client, dump: dump}
  end

  test "a junior can open, correct and confirm a completed invoice while its sibling is still reading",
       c do
    owner = self()

    start_supervised!(
      {Task,
       fn -> send(owner, {:worker_done, perform_job(DumpWorker, %{"dump_id" => c.dump.id})}) end}
    )

    assert_receive {:partial_saved, worker}, 5_000
    second_id = "d#{c.dump.id}_inv_02"
    first_id = "d#{c.dump.id}_inv_01"
    dump = Nila.Repo.reload!(c.dump)
    assert dump.status == "extracting"
    assert [%{"id" => ^second_id}] = dump.invoices
    {:ok, month} = Months.get_by_period(c.org.id, c.client.id, dump.period)
    assert month.invoices == []
    ref = Batch.ref([dump])
    path = "/sales-bills/#{c.client.id}/batch/#{ref}"
    {:ok, view, _} = live(c.conn, path)
    assert has_element?(view, "#sales-bill-#{first_id}", "Reading")
    assert has_element?(view, "#sales-bill-#{second_id}", "21/2025-26")
    assert has_element?(view, "#sales-bills-processing-progress", "1 of 2 ready")
    refute has_element?(view, "#sales-bill-#{first_id} a")
    {:ok, reopened, _} = live(c.conn, path)
    assert has_element?(reopened, "#sales-bill-#{first_id}", "Reading")

    review_path = "/gst/#{c.client.id}/#{dump.period}/sales/invoices/#{second_id}?batch=#{ref}"
    {:ok, review, _} = live(c.conn, review_path)

    assert :sys.get_state(review.pid).socket.assigns.workbench_context.item.invoice["id"] ==
             second_id

    review |> element("#sales-bill-edit-invoice-facts") |> render_click()

    review
    |> form("#sales-bill-invoice-facts-form", invoice_facts: %{invoice_number: "CORRECTED"})
    |> render_submit()

    refute has_element?(review, "#sales-bill-invoice-facts-error")

    {:ok, context} =
      NilaWeb.Gst.InvoiceWorkbench.load(c.org.id, c.client.id, dump.period, second_id, "all")

    assert context.item.invoice["invoice_number"] == "CORRECTED"
    issue = Enum.find(context.item.actionable_issues, &(&1["code"] == "grand_total_mismatch"))
    assert issue
    target = Nila.Gst.Sales.Workings.issue_key(issue)

    review
    |> element("button[phx-click='confirm-gst-issue'][phx-value-target='#{target}']")
    |> render_click()

    assert [%{target: ^target}] = Nila.Gst.Sales.Review.Resolutions.list(month.id)
    assert response(get(c.conn, "/gstr1/#{c.client.id}/#{dump.period}/workings.xlsx"), 422)
    review |> element("#sales-bill-edit-invoice-facts") |> render_click()
    send(worker, :finish)
    assert_receive {:worker_done, :ok}, 5_000
    assert has_element?(review, "#sales-bill-invoice-facts-form")
    assert has_element?(review, "#invoice-review-title", "CORRECTED")
    assert has_element?(view, "#sales-bill-#{second_id}", "CORRECTED")
    refute has_element?(view, "#sales-bill-#{first_id}", "Reading")

    assert has_element?(
             view,
             "#sales-bills-voucher-table tr:first-child[id='sales-bill-#{first_id}']"
           )

    assert has_element?(
             view,
             "#sales-bills-voucher-table tr:nth-child(2)[id='sales-bill-#{second_id}']"
           )

    {:ok, final} = Months.get_by_period(c.org.id, c.client.id, dump.period)
    assert Enum.map(final.invoices, & &1["id"]) == [first_id, second_id]
    workings = Nila.Gst.Sales.Review.Resolutions.workings(final)

    refute Enum.any?(
             workings.issues,
             &(Nila.Gst.Sales.Workings.issue_key(&1) == target and &1["status"] == "open")
           )
  end

  test "a failed sibling keeps completed invoices visible and blocks export", c do
    owner = self()

    start_supervised!(
      {Task,
       fn -> send(owner, {:worker_done, perform_job(DumpWorker, %{"dump_id" => c.dump.id})}) end}
    )

    assert_receive {:partial_saved, worker}, 5_000
    send(worker, :fail)
    assert_receive {:worker_done, :ok}, 5_000
    {:ok, view, _} = live(c.conn, "/sales-bills/#{c.client.id}/batch/#{Batch.ref([c.dump])}")
    assert has_element?(view, "#sales-bill-d#{c.dump.id}_inv_01", "Couldn't read")
    assert has_element?(view, "#sales-bill-d#{c.dump.id}_inv_02", "21/2025-26")
    assert response(get(c.conn, "/gstr1/#{c.client.id}/#{c.dump.period}/workings.xlsx"), 422)

    assert response(
             get(c.conn, "/sales-bills/#{c.client.id}/batch/#{Batch.ref([c.dump])}/tally.xml"),
             422
           )

    dump = Nila.Repo.reload!(c.dump)
    assert {:ok, _} = Dumps.retry_failed(dump)

    start_supervised!(
      {Task,
       fn -> send(owner, {:retry_done, perform_job(DumpWorker, %{"dump_id" => dump.id})}) end},
      id: :retry
    )

    assert_receive {:partial_saved, retry}, 5_000
    {:ok, refreshed, _} = live(c.conn, "/sales-bills/#{c.client.id}/batch/#{Batch.ref([dump])}")
    assert has_element?(refreshed, "#sales-bill-d#{dump.id}_inv_02", "21/2025-26")
    assert has_element?(refreshed, "#sales-bill-d#{dump.id}_inv_01", "Reading")
    assert has_element?(refreshed, "#sales-bills-processing-progress", "1 of 2 ready")
    send(retry, :finish)
    assert_receive {:retry_done, :ok}, 5_000
    assert length(Nila.Repo.reload!(dump).invoices) == 2
  end
end
