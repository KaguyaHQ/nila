defmodule NilaWeb.Gst.PurchaseSourceReview do
  @moduledoc false
  alias Nila.Gst.Purchase.Resolutions

  def correction(row) do
    for key <- ~w(taxable_paise cgst sgst igst cess total_paise), into: %{} do
      value =
        if key in ~w(taxable_paise total_paise),
          do: row[key],
          else: get_in(row, ["tax_paise", key])

      {key, decimal(value || 0)}
    end
  end

  def apply(c, params) do
    with true <- is_binary(params["source_basis"]) and params["source_basis"] != "",
         :ok <- current_basis(c, params["source_basis"]),
         item when not is_nil(item) <- c.item,
         true <- item.kind == :books,
         row when not is_nil(row) <-
           Enum.find(item.books_members, &(&1["id"] == params["books_id"])),
         {:ok, attrs} <- attrs(item, row, params) do
      Resolutions.record_many_and_refresh(c.month, attrs, c.scope.user.id,
        expected_source_basis: params["source_basis"]
      )
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_selection}
    end
  end

  defp current_basis(%{month: nil}, _), do: {:error, :not_found}

  defp current_basis(c, basis) do
    if Resolutions.source_basis(c.month, c.workings) == basis, do: :ok, else: {:error, :stale}
  end

  defp attrs(item, row, %{"action" => action, "portal_ref" => ref})
       when action in ~w(confirm_pair reject_pair) do
    if item.bucket == "possible" and not item.resolved and
         Enum.any?(item.candidates, &(&1.books_id == row["id"] and &1.ref == ref)) do
      {:ok, [%{"verb" => action, "books_id" => row["id"], "gstr2b_ref" => ref}]}
    else
      {:error, :invalid_selection}
    end
  end

  defp attrs(_, row, %{"action" => "correct", "amounts" => amounts, "reason" => reason})
       when is_map(amounts) and is_binary(reason) do
    with {:ok, values, reason} <-
           Nila.Gst.Purchase.SourceCorrections.values(Map.put(amounts, "reason", reason), row) do
      attrs = Nila.Gst.Purchase.SourceCorrections.attrs(row, values, reason)
      if attrs == [], do: {:error, :unchanged}, else: {:ok, attrs}
    end
  end

  defp attrs(_, _, _), do: {:error, :invalid_selection}

  defp decimal(value),
    do: "#{div(value, 100)}.#{String.pad_leading(to_string(rem(value, 100)), 2, "0")}"
end
