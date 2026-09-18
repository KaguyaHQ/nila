defmodule Nila.Gst.Sales.TaxpayerChecks do
  @moduledoc "Sales comparisons against saved taxpayer facts; never edits the printed invoice."
  alias Nila.Gst.Portal.Taxpayers
  alias Nila.Gst.Issues
  alias Nila.Gstin
  import Ecto.Query

  @codes ~w(seller_gst_registration_review buyer_gst_registration_review seller_gst_name_review buyer_gst_name_review)
  def issue?(%{"code" => code}), do: code in @codes
  def issue?(_), do: false

  # A late lookup can add an exception after a human marked the month reviewed.
  # Filed snapshots stay frozen; current reviews must reflect new exceptions.
  def refresh_reviews(gstin) do
    Nila.Repo.transact(fn ->
      months =
        Nila.Repo.all(
          from m in Nila.Gst.Sales.Month,
            where: m.state == "reviewed" and is_nil(m.filed_at),
            order_by: m.id,
            lock: "FOR UPDATE"
        )

      for month <- months do
        workings = Nila.Gst.Sales.Review.Resolutions.workings(month)

        if gstin in gstins(workings.active_invoices) and
             Enum.any?(workings.issues, &(issue?(&1) and &1["status"] == "open")) do
          Nila.Gst.Sales.Invoice.SourceChanges.invalidate_reviews([month])
        end
      end

      {:ok, :checked}
    end)
  end

  def gstins(invoices) do
    invoices
    |> Enum.flat_map(&[&1["seller_gstin"], &1["buyer_gstin"]])
    |> Enum.map(&Taxpayers.normalize/1)
    |> Enum.filter(&Gstin.valid?/1)
    |> Enum.uniq()
  end

  def saved(invoices), do: Taxpayers.saved(gstins(invoices))

  def enqueue(org_id, invoices) do
    config = Application.get_env(:nila, Nila.Integrations.Whitebooks, [])

    if Enum.all?(
         [:client_id, :client_secret, :email],
         &(is_binary(config[&1]) and config[&1] != "")
       ) do
      cached = saved(invoices)

      for gstin <- gstins(invoices), not Taxpayers.fresh?(cached[gstin]) do
        %{org_id: org_id, gstin: gstin}
        |> Nila.Gst.Portal.TaxpayerWorker.new()
        |> Oban.insert!()
      end
    end

    :ok
  end

  def annotate(invoices, %{taxpayers: taxpayers}) do
    Enum.map(invoices, fn invoice ->
      facts =
        Map.new(~w(seller buyer), fn party ->
          gstin = Taxpayers.normalize(invoice[party <> "_gstin"])
          lookup = taxpayers[gstin]

          value =
            if lookup do
              %{
                "gstin" => lookup.gstin,
                "legal_name" => lookup.legal_name,
                "trade_name" => lookup.trade_name,
                "registration_status" => lookup.registration_status,
                "checked_at" => DateTime.to_iso8601(lookup.checked_at)
              }
            end

          {party, value}
        end)

      Map.put(invoice, "taxpayer_checks", facts)
    end)
  end

  def annotate(invoices, _), do: invoices

  def issues(invoices),
    do: Enum.flat_map(invoices, fn i -> Enum.flat_map(outcomes(i), & &1.issues) end)

  def outcomes(invoice) do
    Enum.flat_map(~w(seller buyer), fn party ->
      gstin = Taxpayers.normalize(invoice[party <> "_gstin"])
      facts = get_in(invoice, ["taxpayer_checks", party])

      applicable? =
        not (party == "buyer" and gstin == nil and
               invoice["recipient_registration"] == "unregistered")

      checked? =
        Gstin.valid?(gstin) and is_map(facts) and facts["gstin"] == gstin and recent?(facts)

      name = invoice[party <> "_name"]
      named? = is_binary(name) and String.trim(name) != ""

      detail =
        if checked? do
          names =
            [facts["legal_name"], facts["trade_name"]]
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.uniq()
            |> Enum.join(" / ")

          "GST portal: #{names}; #{facts["registration_status"]}. Checked #{checked_at(facts["checked_at"])}. This is the status at lookup, not on the invoice date."
        else
          if is_map(facts) and facts["gstin"] == gstin,
            do:
              "Last successful check: #{checked_at(facts["checked_at"])}. A current portal check is unavailable.",
            else: "No successful current portal check is available."
        end

      for kind <- ~w(registration name) do
        can_check? = checked? and (kind == "registration" or named?)

        passed? =
          can_check? and
            if(kind == "registration",
              do: String.downcase(facts["registration_status"]) == "active",
              else:
                Enum.any?([facts["legal_name"], facts["trade_name"]], &name_matches?(name, &1))
            )

        code = party <> "_gst_" <> kind <> "_review"

        label =
          String.capitalize(party) <>
            if(kind == "registration",
              do: " GST registration is active",
              else: " name matches GST registration"
            )

        message =
          if kind == "registration",
            do:
              "#{String.capitalize(party)} GST registration is #{facts && facts["registration_status"]}. #{detail}",
            else:
              "#{String.capitalize(party)} name on the bill (#{name}) differs from the GST registration. #{detail}"

        issues =
          if can_check? and not passed? do
            [
              %{
                "code" => code,
                "target" => target(invoice, party, kind, facts),
                "level" => Issues.level_for(code),
                "invoice" => invoice["invoice_number"],
                "source_id" => invoice["id"],
                "fields" => [party <> "_gstin", party <> "_name"],
                "message" => message
              }
            ]
          else
            []
          end

        %{
          id: code,
          label: label,
          detail: detail,
          reason:
            if(checked? and not named? and kind == "name",
              do: "The invoice name is missing.",
              else: detail
            ),
          issues: issues,
          status:
            cond do
              not applicable? -> :not_applicable
              not can_check? -> :not_checked
              passed? -> :passed
              true -> :failed
            end
        }
      end
    end)
  end

  defp target(invoice, party, kind, facts) do
    evidence =
      {Taxpayers.normalize(invoice[party <> "_gstin"]), name_key(invoice[party <> "_name"] || ""),
       facts["legal_name"], facts["trade_name"], facts["registration_status"]}

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(evidence)) |> Base.encode16(case: :lower)

    "#{invoice["id"] || invoice["invoice_number"]}:#{party}_gst_#{kind}_review:#{digest}"
  end

  defp checked_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> time |> DateTime.add(19_800) |> Calendar.strftime("%d %b %Y at %H:%M IST")
      _ -> "unknown"
    end
  end

  defp checked_at(_), do: "unknown"

  defp recent?(%{"checked_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> Taxpayers.fresh_at?(time)
      _ -> false
    end
  end

  defp recent?(_), do: false

  defp name_matches?(left, right) when is_binary(left) and is_binary(right),
    do: name_key(left) != "" and name_key(left) == name_key(right)

  defp name_matches?(_, _), do: false

  defp name_key(name) do
    name
    |> String.downcase()
    |> String.replace(~r/^m\s*\/\s*s\.?\s*/u, "")
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.replace(~r/\bprivate\b/u, "pvt")
    |> String.replace(~r/\blimited\b/u, "ltd")
    |> String.split()
    |> Enum.join("")
  end
end
