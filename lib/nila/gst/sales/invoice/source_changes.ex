defmodule Nila.Gst.Sales.Invoice.SourceChanges do
  @moduledoc "Serializes source edits and invalidates reviews of the affected sales months."

  import Ecto.Query

  alias Nila.Gst.Intake.Dump
  alias Nila.Gst.Sales.Month
  alias Nila.Repo

  @doc "Locks months before their source dumps, matching the intake worker's lock order."
  def lock(org_id, client_id, source_id) do
    months =
      Repo.all(
        from month in Month,
          where: month.org_id == ^org_id and month.client_id == ^client_id,
          where:
            fragment(
              "EXISTS (SELECT 1 FROM unnest(?) AS source(invoice) WHERE COALESCE(invoice->>'id', invoice->>'invoice_number') = ?)",
              month.invoices,
              ^source_id
            ),
          order_by: month.id,
          lock: "FOR UPDATE"
      )

    Repo.all(
      from dump in Dump,
        where: dump.org_id == ^org_id and dump.client_id == ^client_id and dump.kind == "sales",
        where:
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?) AS source(invoice) WHERE COALESCE(invoice->>'id', invoice->>'invoice_number') = ?)",
            dump.invoices,
            ^source_id
          ),
        order_by: dump.id,
        lock: "FOR UPDATE"
    )

    if Enum.any?(months, &(not is_nil(&1.filed_at))) do
      {:error, :filed}
    else
      {:ok, months}
    end
  end

  def invalidate_reviews(months, changed_by_id \\ nil) do
    for month <- months do
      if month.state == "reviewed" do
        month |> Month.changeset(%{state: "worked"}) |> Repo.update!()
      end

      Nila.Gst.Filing.Signoffs.invalidate_gstr3b_in_transaction(month, changed_by_id)
    end

    :ok
  end
end
