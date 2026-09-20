defmodule Nila.Gst.Purchase.ItcTreatment do
  @moduledoc "Exact, per-head treatment of an outstanding credit."
  @heads ~w(cgst sgst igst cess)
  @later [
    {"awaiting_document", "Waiting for invoice"},
    {"awaiting_2b", "Waiting for GSTR-2B"},
    {"review_pending", "Review pending"},
    {"supplier_correction", "Waiting for supplier correction"},
    {"goods_not_received", "Goods or services not received"},
    {"other", "Other"}
  ]
  @exclude [
    {"blocked_credit", "Blocked credit"},
    {"apportionment", "Common credit apportioned"},
    {"pos", "Place of supply restriction"},
    {"personal", "Personal expense"},
    {"duplicate", "Duplicate credit"},
    {"time_barred", "Time limit expired"},
    {"not_ours", "Not our purchase"},
    {"other", "Other"}
  ]
  def reasons("later"), do: @later
  def reasons("exclude"), do: @exclude
  def reasons(_), do: []
  def zero, do: Map.new(@heads, &{&1, 0})
  def heads(map), do: Map.new(@heads, &{&1, Map.get(map || %{}, &1, 0)})
  def sum(map), do: map |> Map.values() |> Enum.sum()
  def add(a, b), do: Map.new(@heads, &{&1, a[&1] + b[&1]})
  def subtract(a, b), do: Map.new(@heads, &{&1, a[&1] - b[&1]})

  def valid?(a),
    do:
      is_map(a) and Enum.sort(Map.keys(a)) == Enum.sort(@heads) and
        Enum.all?(a, fn {_, n} -> is_integer(n) and n >= 0 end)

  def build(opening, attrs) when is_map(attrs) do
    choice = attrs["choice"]

    amounts =
      if choice == "split",
        do: Map.take(attrs, ~w(claim later exclude)),
        else: Map.new(~w(claim later exclude), &{&1, if(&1 == choice, do: opening, else: zero())})

    note = attrs["note"] || ""

    cond do
      choice not in ~w(claim later exclude split) ->
        {:error, :invalid_treatment}

      not Enum.all?(~w(claim later exclude), &valid?(amounts[&1])) ->
        {:error, :invalid_amounts}

      add(add(amounts["claim"], amounts["later"]), amounts["exclude"]) != opening ->
        {:error, :amounts_do_not_balance}

      not is_binary(note) or String.length(note) > 1000 ->
        {:error, :invalid_note}

      not valid_reason?("later", amounts, attrs, note) or
          not valid_reason?("exclude", amounts, attrs, note) ->
        {:error, :reason_required}

      true ->
        {:ok,
         Map.merge(amounts, Map.take(attrs, ~w(choice later_reason exclude_reason)))
         |> Map.put("note", String.trim(note))
         |> Map.put("opening_heads", opening)}
    end
  end

  def build(_, _), do: {:error, :invalid_treatment}

  defp valid_reason?(kind, amounts, attrs, note) do
    code = attrs[kind <> "_reason"]

    sum(amounts[kind]) == 0 or
      (Enum.any?(reasons(kind), &(elem(&1, 0) == code)) and
         (code != "other" or String.trim(note) != ""))
  end

  def project(total, events, allocations, period) do
    decisions =
      events
      |> Enum.filter(
        &(&1.event_type == "treatment_decided" and &1.effective_client_month.period <= period)
      )
      |> Enum.group_by(& &1.effective_client_month.period)
      |> Map.new(fn {p, es} -> {p, Enum.max_by(es, & &1.id)} end)

    prior = Enum.filter(decisions, fn {p, _} -> p < period end)

    consumed =
      Enum.reduce(prior, zero(), fn {_, e}, acc ->
        add(acc, add(heads(e.payload["claim"]), heads(e.payload["exclude"])))
      end)

    consumed =
      Enum.reduce(allocations, consumed, fn a, acc ->
        if is_nil(a.revoked_at) and a.client_month.period < period and
             not Map.has_key?(decisions, a.client_month.period),
           do: add(acc, heads(a.tax_heads)),
           else: acc
      end)

    latest = decisions |> Enum.max_by(fn {p, _} -> p end, fn -> nil end)
    reviewed_total = if latest, do: elem(latest, 1).payload["source_heads"] || total, else: total
    opening = subtract(total, consumed)
    current = decisions[period]
    inherited = prior |> Enum.max_by(fn {p, _} -> p end, fn -> nil end)

    payload =
      cond do
        current ->
          current.payload

        inherited ->
          %{
            "choice" => "later",
            "claim" => zero(),
            "later" => opening,
            "exclude" => zero(),
            "later_reason" => elem(inherited, 1).payload["later_reason"],
            "note" => elem(inherited, 1).payload["note"]
          }

        true ->
          %{"choice" => "undecided", "claim" => zero(), "later" => zero(), "exclude" => zero()}
      end

    %{
      treatment: payload["choice"],
      treatment_heads: Map.take(payload, ~w(claim later exclude)),
      outstanding_heads: opening,
      explicit_treatment?: not is_nil(current),
      later_reason: payload["later_reason"],
      exclude_reason: payload["exclude_reason"],
      treatment_note: payload["note"],
      treatment_stale?:
        total != reviewed_total or not valid?(opening) or
          (current != nil and heads(current.payload["opening_heads"]) != opening)
    }
  end
end
