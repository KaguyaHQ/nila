defmodule Nila.Gst.Portal.Taxpayers do
  @moduledoc "Latest successful public taxpayer lookup per GSTIN. No client session is needed."
  import Ecto.Query
  alias Nila.{Gstin, Repo}
  alias Nila.Gst.Portal.TaxpayerLookup
  alias Nila.Integrations.Whitebooks

  @max_age 30 * 24 * 60 * 60
  def normalize(gstin) when is_binary(gstin), do: gstin |> String.trim() |> String.upcase()
  def normalize(_), do: nil

  def fresh?(%TaxpayerLookup{checked_at: checked_at}), do: fresh_at?(checked_at)
  def fresh?(_), do: false

  def fresh_at?(%DateTime{} = checked_at),
    do: DateTime.diff(DateTime.utc_now(), checked_at) in 0..(@max_age - 1)

  def saved(gstins) do
    gstins = gstins |> Enum.map(&normalize/1) |> Enum.filter(&Gstin.valid?/1) |> Enum.uniq()

    Repo.all(from t in TaxpayerLookup, where: t.gstin in ^gstins)
    |> Map.new(&{&1.gstin, &1})
  end

  def lookup(gstin) do
    gstin = normalize(gstin)

    if Gstin.valid?(gstin) do
      existing = Repo.get_by(TaxpayerLookup, gstin: gstin)
      if fresh?(existing), do: {:ok, existing}, else: refresh(gstin)
    else
      {:error, :invalid_gstin}
    end
  end

  defp refresh(gstin) do
    # An older concurrent request must not overwrite a newer successful result.
    checked_at = DateTime.utc_now()

    with {:ok, response} <- Whitebooks.search_taxpayer(gstin),
         {:ok, facts} <- Whitebooks.taxpayer_facts(response, gstin) do
      attrs = Map.merge(facts, %{checked_at: checked_at, provider: "whitebooks"})

      replace =
        from t in TaxpayerLookup,
          where: t.checked_at < ^checked_at,
          update: [set: ^Map.to_list(Map.put(attrs, :updated_at, DateTime.utc_now()))]

      with {:ok, _} <-
             %TaxpayerLookup{gstin: gstin}
             |> Ecto.Changeset.change(attrs)
             |> Repo.insert(on_conflict: replace, conflict_target: [:gstin]) do
        Repo.fetch_by(TaxpayerLookup, gstin: gstin)
      end
    end
  end
end
