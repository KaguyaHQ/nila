defmodule Nila.Gst.Resolutions do
  @moduledoc """
  Append-only persistence for human decisions on a worked month's exceptions,
  and the single assembler that layers them over the engine's recon.

  A month is rendered by `workings/1`: it takes the pristine `recon`, folds in
  every resolution (`Workings.materialize`), recomputes flags against the
  client's entity context on the corrected invoices, and rebuilds the register
  rows and summary via `Register`. Every surface — the register table, the
  exceptions queue, the Typst pack — reads through this one function, so they
  cannot drift from the stored decisions.
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Clients

  alias Nila.Gst.{
    ClientMonth,
    EntityContext,
    Flags,
    Gstr3b,
    ItcPosition,
    Register,
    Resolution,
    SalesMonths,
    Workings
  }

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
  Records one decision. `org_id` and `client_month_id` are set on the struct,
  never cast (tenancy is not user-supplied). `decided_by_id` attributes the
  call. Returns `{:ok, resolution} | {:error, changeset}`.
  """
  def record(%ClientMonth{} = month, attrs, decided_by_id) do
    %Resolution{
      org_id: month.org_id,
      client_month_id: month.id,
      decided_by_id: decided_by_id
    }
    |> Resolution.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The effective workings for a month: register rows and summary after every
  human resolution is applied over the engine's recon. This is the projection
  every surface renders.
  """
  def workings(%ClientMonth{} = month) do
    resolutions = month.id |> list() |> Enum.map(&resolution_map/1)
    recon = Workings.materialize(month.recon, resolutions)

    invoices = Workings.books_invoices(recon)
    flags = flags_for(month, invoices)
    rows = Register.rows(invoices, recon, flags)
    itc = ItcPosition.compute(recon, rows, Workings.itc_decisions(resolutions))

    %{
      recon: recon,
      baseline: Workings.materialize(month.recon, []),
      decisions: Workings.decisions(resolutions),
      itc: itc,
      gstr3b: gstr3b(month, recon, itc),
      rows: rows,
      summary: Register.summary(rows)
    }
  end

  # The assembled 3B for the month. Outward liability comes from the client's
  # worked sales month (GSTR-1 derivation) when one exists; without it the
  # return is assembled with zero liability and marked so the UI never shows a
  # cash-payable figure computed from a liability we don't have.
  defp gstr3b(%ClientMonth{} = month, recon, itc) do
    {source, liability} =
      case SalesMonths.get_by_period(month.org_id, month.client_id, month.period) do
        {:ok, %{derived_gstr1: derived}} when map_size(derived) > 0 ->
          {"gstr1_derived", Gstr3b.liability_from_gstr1(derived)}

        _ ->
          {"missing", %{"txval" => 0, "igst" => 0, "cgst" => 0, "sgst" => 0}}
      end

    liability
    |> Gstr3b.assemble(recon, itc)
    |> Map.put("liability_source", source)
  end

  defp flags_for(%ClientMonth{} = month, invoices) do
    {:ok, client} = Clients.get_client(month.org_id, month.client_id)
    entity_ctx = EntityContext.for_client(client)
    vendor_dir = vendor_dir(month.recon)
    Flags.evaluate_all(invoices, entity_ctx, vendor_dir)
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
