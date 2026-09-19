defmodule Nila.Gst.Purchase.Resolutions do
  @moduledoc """
  Append-only persistence for human decisions on a worked month's exceptions,
  and the single assembler that layers them over the engine's recon.

  A month is rendered by `workings/1`: it takes the pristine `recon`, folds in
  every resolution (`Workings.materialize`), recomputes flags against the
  client's entity context on the corrected invoices, and rebuilds the register
  rows and summary via `Register`. Every surface — the register table, the
  exceptions queue, the 3B — reads through this one function, so they cannot
  drift from the stored decisions.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Clients

  alias Nila.Gst.Filing.{Gstr3b, ItcPosition, Signoffs}
  alias Nila.Gst.Hsn.Directory

  alias Nila.Gst.Purchase.{
    Flags,
    Groups,
    ItcCases,
    Month,
    Register,
    Resolution,
    Review,
    TaxpayerContext,
    Workings
  }

  alias Nila.Gst.Rates.Directory, as: RateDirectory
  alias Nila.Gst.Sales.Review.Resolutions, as: SalesResolutions
  alias Nila.Gst.Sales.Months, as: SalesMonths

  alias Nila.Repo

  @doc "Resolutions for a month, oldest first (append-only replay order)."
  def list(client_month_id) do
    Repo.all(
      from r in Resolution,
        where: r.client_month_id == ^client_month_id,
        order_by: [asc: r.inserted_at, asc: r.id]
    )
  end

  @doc """
  Records one decision and refreshes the month's persisted effective projection.
  Returns `{:ok, resolution} | {:error, reason}`.
  """
  def record(%Month{} = month, attrs, decided_by_id) do
    case record_and_refresh(month, attrs, decided_by_id) do
      {:ok, %{resolution: resolution}} -> {:ok, resolution}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Records one decision and atomically refreshes the effective projection."
  def record_and_refresh(%Month{} = month, attrs, decided_by_id) do
    record_many_and_refresh(month, [attrs], decided_by_id)
  end

  @doc "Records a batch of decisions and atomically refreshes the effective projection."
  def record_many_and_refresh(%Month{} = month, attrs_list, decided_by_id) do
    Repo.transact(fn ->
      month = lock_month(month)

      with :ok <- refuse_signed(month),
           {:ok, resolutions} <- insert_all(month, attrs_list, decided_by_id) do
        :ok = ItcCases.separate_rejected_pairs(month, attrs_list, decided_by_id)
        workings = workings(month)
        :ok = ItcCases.sync_month(month, workings.recon)
        workings = workings(month)

        month =
          month
          |> Month.changeset(%{register_rows: workings.rows, summary: workings.summary})
          |> Repo.update!()
          |> Repo.preload(:client)

        {:ok,
         %{
           resolution: List.first(resolutions),
           resolutions: resolutions,
           month: month,
           workings: workings
         }}
      end
    end)
  end

  def record_itc_case_event_and_refresh(
        %Month{} = month,
        case_id,
        event_type,
        resolution_attrs,
        decided_by_id
      ) do
    Repo.transact(fn ->
      month = lock_month(month)

      with :ok <- refuse_signed(month),
           {:ok, event} <-
             ItcCases.insert_event(month, case_id, event_type, decided_by_id),
           {:ok, resolutions} <- insert_all(month, resolution_attrs, decided_by_id) do
        workings = workings(month)

        month =
          month
          |> Month.changeset(%{register_rows: workings.rows, summary: workings.summary})
          |> Repo.update!()
          |> Repo.preload(:client)

        {:ok, %{event: event, resolutions: resolutions, month: month, workings: workings}}
      end
    end)
  end

  defp lock_month(%Month{id: id}) do
    Repo.one!(from m in Month, where: m.id == ^id, lock: "FOR UPDATE")
  end

  defp refuse_signed(%Month{} = month) do
    case Signoffs.latest_signoff(month.id) do
      {:ok, _signoff} -> {:error, :signed_off}
      {:error, :not_found} -> :ok
    end
  end

  defp insert_all(month, attrs_list, decided_by_id) do
    Enum.reduce_while(attrs_list, {:ok, []}, fn attrs, {:ok, resolutions} ->
      result =
        %Resolution{
          org_id: month.org_id,
          client_month_id: month.id,
          decided_by_id: decided_by_id
        }
        |> Resolution.changeset(attrs)
        |> Repo.insert()

      case result do
        {:ok, resolution} -> {:cont, {:ok, [resolution | resolutions]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, resolutions} -> {:ok, Enum.reverse(resolutions)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  The effective workings for a month: register rows and summary after every
  human resolution is applied over the engine's recon. This is the projection
  every surface renders.
  """
  def workings(%Month{} = month) do
    resolutions = month.id |> list() |> Enum.map(&resolution_map/1)
    recon = Workings.materialize(month.recon, resolutions)

    invoices = Workings.books_invoices(recon)
    case_lines = ItcCases.list_for_month(month)
    carried_books = ItcCases.carried_books(case_lines)
    flags = flags_for(month, Enum.uniq_by(invoices ++ carried_books, & &1["id"]))
    groups = Groups.build(recon)
    rows = Register.rows(invoices, recon, flags)
    claim_rows = ItcCases.claim_rows(case_lines, flags)
    attestation = Workings.document_attestation(recon, rows, resolutions)
    document_cases = ItcCases.document_cases(case_lines)

    itc =
      recon
      |> ItcPosition.compute(rows ++ claim_rows, Workings.itc_decisions(resolutions), case_lines)
      |> ItcPosition.apply_document_cases(case_lines)

    summary =
      month
      |> summary(rows, groups)
      |> Map.put(
        "lane_decisions",
        Review.open_decision_count(%{
          groups: groups,
          itc: itc,
          document_attestation: attestation,
          document_cases: document_cases
        })
      )

    %{
      recon: recon,
      baseline: Workings.materialize(month.recon, []),
      decisions: Workings.decisions(resolutions),
      accepted_reasons: Workings.accepted_reasons(resolutions),
      gstr2b_decisions: Workings.gstr2b_decisions(resolutions),
      document_attestation: attestation,
      case_lines: case_lines,
      document_cases: document_cases,
      itc: itc,
      gstr3b: gstr3b(month, recon, itc),
      groups: groups,
      rows: rows,
      summary: summary
    }
  end

  # Rows are re-derived from the resolutions; the extraction ledger's
  # month-level flags are not derivable from them, so they carry over from the
  # summary extraction persisted.
  defp summary(%Month{} = month, rows, groups) do
    Map.merge(Register.summary(rows, groups), Map.take(month.summary || %{}, ["document_flags"]))
  end

  # Open months use the current sales working. Filed months keep their recorded
  # return. Sales review does not create a separate approval.
  defp gstr3b(%Month{} = month, recon, itc) do
    {source, outward} =
      case SalesMonths.get_by_period(month.org_id, month.client_id, month.period) do
        {:ok, sales_month} -> gstr1_outward(sales_month)
        {:error, :not_found} -> missing_outward()
      end

    outward.liability
    |> Gstr3b.assemble(recon, itc, outward.interstate_unregistered)
    |> Map.put("liability_source", source)
  end

  defp gstr1_outward(sales_month) do
    cond do
      not is_nil(sales_month.filed_at) ->
        {"gstr1_filed",
         outward_projection(SalesResolutions.effective_workings(sales_month).derived)}

      sales_month.invoices != [] or sales_month.state == "reviewed" ->
        source = if sales_month.state == "reviewed", do: "gstr1_reviewed", else: "gstr1_derived"
        {source, outward_projection(SalesResolutions.effective_workings(sales_month).derived)}

      true ->
        missing_outward()
    end
  end

  defp outward_projection(derived) do
    %{
      liability: Gstr3b.liability_from_gstr1(derived),
      interstate_unregistered: Gstr3b.interstate_unregistered_from_gstr1(derived)
    }
  end

  defp missing_outward do
    {"missing",
     %{
       liability: %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0},
       interstate_unregistered: []
     }}
  end

  defp flags_for(%Month{} = month, invoices) do
    {:ok, client} = Clients.get_client(month.org_id, month.client_id)

    entity_ctx =
      client
      |> TaxpayerContext.for_client()
      |> maybe_put_hsn_directory(month.hsn_master_release_id)
      |> maybe_put_rate_directory(month.gst_rate_release_id)

    vendor_dir = vendor_dir(month.recon)
    Flags.evaluate_all(invoices, entity_ctx, vendor_dir)
  end

  defp maybe_put_hsn_directory(entity_ctx, release_id) do
    directory = if release_id, do: Directory.load(release_id), else: Directory.active()

    case directory do
      {:ok, directory} -> Map.put(entity_ctx, "hsn_directory", directory)
      {:error, :not_found} -> entity_ctx
    end
  end

  defp maybe_put_rate_directory(entity_ctx, release_id) do
    directory = if release_id, do: RateDirectory.load(release_id), else: RateDirectory.active()

    case directory do
      {:ok, directory} -> Map.put(entity_ctx, "rate_directory", directory)
      {:error, :not_found} -> entity_ctx
    end
  end

  defp vendor_dir(recon) do
    recon
    |> Workings.gstr2b_invoices()
    |> Map.new(fn g -> {g["vendor_gstin"], g["vendor_name"]} end)
  end

  defp resolution_map(%Resolution{} = r) do
    %{
      "verb" => r.verb,
      "books_id" => r.books_id,
      "gstr2b_ref" => r.gstr2b_ref,
      "payload" => r.payload
    }
  end
end
