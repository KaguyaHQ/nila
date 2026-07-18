defmodule Nila.Gst.Chase do
  @moduledoc """
  The intake chase for a client's GST month: what has arrived, what the engine
  says is still missing, and the drafted message asking for it.

  Nila drafts the ask from authoritative knowledge — the compliance calendar,
  the intake slots, and engine-derived gaps (2B bills the client never sent,
  holes in their own invoice sequence). The firm can send the draft manually,
  or a consenting client can receive it through the firm's connected WhatsApp
  or Gmail account. `record_ask/2` logs every delivery append-only so reminders
  don't repeat and the cockpit shows "asked N days ago".
  """

  import Ecto.Query, only: [from: 2]

  alias Nila.Formatters
  alias Nila.Gst.{Calendar, ChaseAsk, ClientMonth, ClientMonths, Resolutions, SalesMonths}
  alias Nila.Orgs.Org
  alias Nila.Repo

  @doc """
  What has arrived for `(org, client, period)`: `purchase` when a worked
  `ClientMonth` exists (the purchase dump was processed), `sales` when a
  worked `SalesMonth` exists. Derived from the existing aggregates — intake
  state needs no schema of its own.
  """
  def slots(org_id, client_id, period) do
    %{
      purchase: match?({:ok, _}, ClientMonths.get_by_period(org_id, client_id, period)),
      sales: match?({:ok, _}, SalesMonths.get_by_period(org_id, client_id, period))
    }
  end

  @doc """
  Engine-derived gaps for a worked month: the *effective* recon's
  `in_2b_not_books` entries (bills vendors filed that the client never sent,
  after human resolutions are applied) and any `sequence_gaps` issues from the
  worked sales month when one exists.
  """
  def gaps(%ClientMonth{} = month) do
    recon = Resolutions.workings(month).recon

    sequence_issues =
      case SalesMonths.get_by_period(month.org_id, month.client_id, month.period) do
        {:ok, sales_month} ->
          Enum.filter(sales_month.issues, &(&1["code"] == "sequence_gaps"))

        {:error, :not_found} ->
          []
      end

    %{
      in_2b_not_books: recon["in_2b_not_books"] || [],
      sequence_issues: sequence_issues
    }
  end

  @doc """
  Drafts the chase message as plain multiline text for manual or automated
  delivery. The value is the specificity: named vendors, amounts, real due
  dates. The register is the Indian professional one — the message goes out in
  the firm's name and closes with the firm's signature, so a proprietor
  reading it knows exactly who is asking.

  `:month_open` is the opening nudge for a period whose dumps haven't arrived.
  """
  def draft(:month_open, %Org{} = org, client, period) do
    dates = Calendar.due_dates(period)
    month = month_name(period)

    """
    Dear #{client.name},

    GST filing for #{month_label(period)} is open. Please send us your #{month} sales invoices and purchase bills for filing.

    GSTR-1 is due #{Formatters.format_display_date(dates.gstr1)} — sending them early helps us file on time.

    #{signature(org)}\
    """
  end

  @doc """
  `:missing_bills` chases the specific gaps from `gaps/1`: each 2B-only bill
  is listed with vendor, invoice number, and amount; sequence gaps in the
  client's own invoices are relayed in their own words.
  """
  def draft(:missing_bills, %Org{} = org, client, period, gaps) do
    sections =
      [
        missing_bills_section(period, gaps.in_2b_not_books),
        sequence_section(gaps.sequence_issues)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    """
    Dear #{client.name},

    #{sections}

    GSTR-3B for #{month_label(period)} is due #{Formatters.format_display_date(due(period))} — please send these across soon so we can file on time.

    #{signature(org)}\
    """
  end

  @doc """
  Logs one sent ask, append-only. `org_id`/`client_id` come from the scoped
  lookup and optional `sent_by_id` from the current user — set on the struct,
  never cast. Automated asks have no human sender and identify their channel.
  """
  def record_ask(%{org_id: org_id, client_id: client_id} = scope, attrs) do
    %ChaseAsk{org_id: org_id, client_id: client_id, sent_by_id: scope[:sent_by_id]}
    |> ChaseAsk.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The most recent ask for `(org, client, period)`, any kind.
  `{:error, :not_found}` when the client has never been chased for the period.
  """
  def last_ask(org_id, client_id, period) do
    Repo.fetch_one(
      from a in ChaseAsk,
        where: a.org_id == ^org_id and a.client_id == ^client_id and a.period == ^period,
        order_by: [desc: a.inserted_at, desc: a.id],
        limit: 1
    )
  end

  @doc "All asks for `(org, client, period)`, newest first, `sent_by` preloaded."
  def list_asks(org_id, client_id, period) do
    Repo.all(
      from a in ChaseAsk,
        where: a.org_id == ^org_id and a.client_id == ^client_id and a.period == ^period,
        order_by: [desc: a.inserted_at, desc: a.id],
        preload: [:sent_by]
    )
  end

  defp missing_bills_section(_period, []), do: nil

  defp missing_bills_section(period, entries) do
    lines =
      Enum.map_join(entries, "\n", fn entry ->
        g = entry["gstr2b"] || entry

        "• #{g["vendor_name"]} — invoice #{g["invoice_number"]}, #{Formatters.format_money_with_paise(g["total_paise"])}"
      end)

    """
    While preparing your #{month_label(period)} GST return, we found #{bills_phrase(length(entries))} your vendors have reported to the portal that we haven't received from you:

    #{lines}

    Please send these bills (a photo or PDF is fine) so we can claim the input credit.\
    """
  end

  defp sequence_section([]), do: nil

  defp sequence_section(issues) do
    notes = Enum.map_join(issues, "\n", & &1["message"])

    """
    We also noticed gaps in your own invoice numbering — #{notes}. If any of these were cancelled, just let us know; otherwise please send the missing invoices too.\
    """
  end

  defp bills_phrase(1), do: "a bill"
  defp bills_phrase(n), do: "#{n} bills"

  defp signature(org) do
    ["Regards,", org.name, org.contact_phone]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp due(period), do: Calendar.due_dates(period).gstr3b

  defp month_label(period) do
    period |> first_of_month() |> Elixir.Calendar.strftime("%B %Y")
  end

  defp month_name(period) do
    period |> first_of_month() |> Elixir.Calendar.strftime("%B")
  end

  defp first_of_month(period) do
    [year, month] = period |> String.split("-") |> Enum.map(&String.to_integer/1)
    Date.new!(year, month, 1)
  end
end
