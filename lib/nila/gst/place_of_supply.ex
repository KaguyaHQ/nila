defmodule Nila.Gst.PlaceOfSupply do
  @moduledoc """
  Document-level, kind-aware Place of Supply derivation — the single authority
  shared by the quote and invoice paths so the two cannot drift (and so the
  invoice path stops using the goods-only `site.state_code` rule that issues
  wrong tax for services).

  A GST invoice legally carries exactly **one** place of supply, and supplier
  state + PoS fix one tax treatment for the whole document. So PoS is genuinely
  document-level — never per line. We derive it from the lines' kinds and the
  two candidate states:

    * **goods** → the **bill-to (buyer registration)** state. Almost every sale
      here is a bill-to-ship-to: the registered buyer (the OEM) directs delivery
      to a third-party site, so under §10(1)(b) IGST Act the place of supply
      follows the *directing* party — the bill-to — not the physical ship-to.
      We fall back to the **ship-to** state (the §10(1)(a) movement terminus)
      only when there is no registered buyer to govern (unregistered / B2C).
    * **service** → the **buyer registration** state (recipient location, §12(2)).

  So for a registered buyer goods and services now resolve to the *same* state —
  the old goods-follow-ship-to rule manufactured spurious `{:divergent, ...}`
  splits (and wrong IGST/CGST treatment) whenever the OEM's HO state differed
  from the site's. With both kinds keyed to the buyer, `{:divergent, ...}` no
  longer arises from a goods/service mix; the branch is retained for the
  composite-/immovable-property rules below, which can reintroduce a genuine
  two-state document.

  `derive_pos/1` returns:

    * `{:ok, state_name}`     — every line's rule resolves to the same state;
    * `{:divergent, states}`  — goods and services resolve to *different* states;
      one invoice can't legally hold two treatments, so the caller must warn and
      **split into two invoices**, never persist a blended PoS;
    * `:ambiguous`            — a needed state is missing (or there are no lines);
      the caller flags it and falls back to the explicit override.

  Pure on purpose — plain strings in, no schemas or DB — so the rule is testable
  in one place. The composite-supply and immovable-property judgments (which can
  flip a service line to the goods/site rule) are operator decisions surfaced via
  the document's `place_of_supply_overridden` flag, and tune *inside* this module
  without changing its interface. `seller_state` is accepted for interface
  stability (a future immovable-property rule needs it) though PoS selection does
  not use it today.
  """

  @doc """
  Derives the document's place of supply from its inputs.

  Expects a map with:

    * `:line_kinds` — list of `"goods"`/`"service"` strings (one per line item);
    * `:ship_to_state` — the ship-to state **name** (goods rule input);
    * `:buyer_registration_state` — the buyer registration state **name** (service rule input);
    * `:seller_state` — accepted but unused today (interface stability).
  """
  def derive_pos(%{line_kinds: line_kinds} = inputs) when is_list(line_kinds) do
    ship_to = inputs[:ship_to_state]
    buyer = inputs[:buyer_registration_state]

    required =
      line_kinds
      |> Enum.uniq()
      |> Enum.map(fn
        "service" -> buyer
        _goods -> goods_pos(buyer, ship_to)
      end)

    cond do
      required == [] -> :ambiguous
      Enum.any?(required, &blank?/1) -> :ambiguous
      match?([_], Enum.uniq(required)) -> {:ok, hd(Enum.uniq(required))}
      true -> {:divergent, Enum.uniq(required)}
    end
  end

  def derive_pos(_), do: :ambiguous

  # §10(1)(b): in a bill-to-ship-to the registered bill-to party directs the
  # delivery, so place of supply is *its* state, not the ship-to site. Fall back
  # to the ship-to (movement terminus, §10(1)(a)) only when no registered buyer
  # governs.
  defp goods_pos(buyer, ship_to), do: if(blank?(buyer), do: ship_to, else: buyer)

  defp blank?(value), do: value in [nil, ""]
end
