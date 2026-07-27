defmodule Nila.Gst.Intake.EvidenceBackfill do
  @moduledoc """
  Gives an already-extracted dump its page pictures back, without re-reading it.

  Rendering arrived after the Mistral extractor did, so every month extracted
  before it has invoices that point at no scanned bill — the register is right,
  the evidence beside it is missing. The fix is local: the original file is still
  in Storage, and every invoice kept the page numbers it was read from
  (`"pages"` on purchase, `"source_pages"`/`"page"` on sales). Rasterize, store
  under the same dump-namespaced basenames extraction would have used, write the
  names back, re-derive.

  **Why not re-extract.** The provider would answer again, and it need not answer
  identically: a different invoice count or order re-numbers the positional ids
  (`"inv_01"`, `"inv_02"` — `Nila.Gst.Purchase.Books`) that resolutions are keyed
  on, silently re-pointing a reviewer's decisions at different bills. A render
  cannot change the invoice set, only fill in `images`. That, not the money, is
  the argument.

  Derivation goes through `DumpWorker.settle/1` rather than writing months
  directly, so a signed month refuses the backfill the same way it refuses a
  late arrival — `held`, not overwritten.
  """

  alias Nila.Gst.Extraction.Windowed
  alias Nila.Gst.Intake.{Dump, Dumps, DumpWorker}
  alias Nila.Gst.Purchase.Months, as: PurchaseMonths
  alias Nila.Gst.Sales.Months, as: SalesMonths
  alias Nila.Repo
  alias Nila.Storage

  import Ecto.Query, only: [from: 2]

  @kinds ~w(purchase sales)

  @doc """
  Extracted purchase/sales dumps with at least one invoice and no image on any
  of them.

  A dump whose invoices already name their pages is skipped whether or not the
  bytes are still in Storage — repairing a missing *file* is a different problem
  and a louder one than a missing picture.
  """
  @spec pending(keyword()) :: [Dump.t()]
  def pending(opts \\ []) do
    query =
      from d in Dump,
        where: d.kind in @kinds and d.status == "extracted",
        order_by: [asc: d.id]

    query
    |> maybe_scope(opts)
    |> Repo.all()
    |> Enum.filter(&missing_evidence?/1)
  end

  defp maybe_scope(query, opts) do
    case Keyword.get(opts, :dump_id) do
      nil -> query
      id -> from d in query, where: d.id == ^id
    end
  end

  defp missing_evidence?(%Dump{invoices: invoices}) when is_list(invoices) and invoices != [],
    do: not Enum.any?(invoices, &named_image?/1)

  defp missing_evidence?(%Dump{}), do: false

  defp named_image?(invoice) do
    is_binary(invoice["image"]) or (is_list(invoice["images"]) and invoice["images"] != [])
  end

  @doc """
  Renders one dump's pages, stores them, writes the names onto its invoices and
  re-derives the month.

  `{:ok, %{dump_id: _, pages: _, invoices: _}}` on success — `invoices` counts
  the ones that ended up pointing at a page, which is not always all of them: an
  invoice extraction could not place has no page to point at and keeps none,
  exactly as a fresh extraction would leave it.
  """
  @spec run(Dump.t()) :: {:ok, map()} | {:error, term()}
  def run(%Dump{} = dump) do
    with {:ok, bytes} <- read_source(dump),
         {:ok, images} when images != %{} <- render(dump, bytes) do
      store(dump, images)

      invoices = Enum.map(dump.invoices, &attach(&1, dump, images))

      dump
      |> Dumps.mark_extracted(invoices, cleared_gap(dump))
      |> DumpWorker.settle()

      {:ok,
       %{
         dump_id: dump.id,
         pages: map_size(images),
         invoices: Enum.count(invoices, &named_image?/1)
       }}
    else
      {:ok, empty} when empty == %{} -> {:error, {:nothing_rendered, dump.id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_source(%Dump{file_keys: [key | _rest]}) when is_binary(key), do: Storage.get(key)
  defp read_source(%Dump{id: id}), do: {:error, {:no_source_file, id}}

  defp render(%Dump{file_keys: [key | _rest]}, bytes),
    do: Windowed.render_pages(bytes, filename: Path.basename(key))

  # The same namespacing a fresh extraction applies, and it has to be the same:
  # these basenames are what the evidence controller resolves back to a key.
  defp store(dump, images) do
    key_fun = key_fun(dump)

    Enum.each(images, fn {basename, bytes} ->
      key = key_fun.(dump.org_id, dump.client_id, dump.period, namespace(dump, basename))
      {:ok, _stored} = Storage.put(key, bytes, content_type: "image/png")
    end)
  end

  defp key_fun(%Dump{kind: "sales"}), do: &SalesMonths.evidence_key/4
  defp key_fun(%Dump{}), do: &PurchaseMonths.evidence_key/4

  defp namespace(%Dump{id: id}, basename), do: "d#{id}_#{basename}"

  # Purchase invoices carry a list of pages and take a list of images; sales
  # carry one page and take one. Both point only where a page was actually
  # rendered — a name for a page that does not exist is a 404 wearing evidence.
  defp attach(invoice, %Dump{kind: "sales"} = dump, images) do
    case invoice |> page_numbers() |> List.first() do
      nil -> Map.put(invoice, "image", nil)
      page -> Map.put(invoice, "image", basename_if_rendered(page, dump, images))
    end
  end

  defp attach(invoice, dump, images) do
    names =
      invoice
      |> page_numbers()
      |> Enum.map(&basename_if_rendered(&1, dump, images))
      |> Enum.reject(&is_nil/1)

    Map.put(invoice, "images", names)
  end

  defp basename_if_rendered(page, dump, images) do
    basename = Windowed.page_basename(page)
    if is_map_key(images, basename), do: namespace(dump, basename)
  end

  defp page_numbers(invoice) do
    [invoice["pages"], invoice["source_pages"], invoice["page"]]
    |> Enum.find(&usable_pages?/1)
    |> List.wrap()
    |> List.flatten()
    |> Enum.filter(&is_integer/1)
  end

  defp usable_pages?(pages) when is_list(pages), do: Enum.any?(pages, &is_integer/1)
  defp usable_pages?(page) when is_integer(page), do: true
  defp usable_pages?(_other), do: false

  # The dump may have been recorded as an evidence gap when it had none of its
  # own doing. Now that it has pictures the flag would outlive its reason.
  defp cleared_gap(%Dump{meta: meta}) when is_map(meta),
    do: Map.put(meta, "evidence_unavailable", false)

  defp cleared_gap(%Dump{}), do: %{"evidence_unavailable" => false}
end
