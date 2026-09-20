defmodule Nila.Gst.Purchase.Groups do
  @moduledoc """
  Derives review groups from an effective purchase reconciliation.

  A group is one connected component of the bipartite books-to-GSTR-2B
  candidate graph. The key is render-local and derived from sorted durable
  books IDs and GSTR-2B content references; it is never persisted as business
  state or written back into reconciliation entries.
  """

  alias Nila.Gst.Purchase.Reconciliation

  @paired_buckets ~w(matched value_mismatch)

  @doc "Builds one review group per connected component in an effective recon."
  def build(recon) when is_map(recon) do
    graph =
      Enum.reduce(@paired_buckets, empty_graph(), fn bucket, graph ->
        Enum.reduce(recon[bucket] || [], graph, &put_pair(&2, &1, bucket))
      end)

    graph =
      Enum.reduce(recon["needs_human"] || [], graph, fn entry, graph ->
        books = entry["books"]
        graph = put_books(graph, books, entry, "needs_human")

        Enum.reduce(entry["candidates"] || [], graph, fn counterpart, graph ->
          graph
          |> put_counterpart(counterpart, entry, "needs_human")
          |> put_edge(books, counterpart, "needs_human")
        end)
      end)

    graph =
      Enum.reduce(recon["in_books_not_2b"] || [], graph, fn entry, graph ->
        put_books(graph, entry["books"], entry, "in_books_not_2b")
      end)

    graph =
      Enum.reduce(recon["in_2b_not_books"] || [], graph, fn entry, graph ->
        put_counterpart(graph, entry["gstr2b"] || entry, entry, "in_2b_not_books")
      end)

    graph
    |> components()
    |> Enum.map(&to_group(graph, &1))
    |> Enum.sort_by(& &1.key)
  end

  def build(_recon), do: []

  defp empty_graph do
    %{nodes: %{}, adjacency: %{}, edges: %{}}
  end

  defp put_pair(graph, entry, bucket) do
    books = entry["books"]
    counterpart = entry["gstr2b"]

    graph
    |> put_books(books, entry, bucket)
    |> put_counterpart(counterpart, entry, bucket)
    |> put_edge(books, counterpart, bucket)
  end

  defp put_books(graph, nil, _entry, _bucket), do: graph

  defp put_books(graph, books, entry, bucket) do
    ref = books_ref(books)
    put_node(graph, ref, %{kind: :books, value: books, entries: [{bucket, entry}]})
  end

  defp put_counterpart(graph, nil, _entry, _bucket), do: graph

  defp put_counterpart(graph, counterpart, entry, bucket) do
    ref = counterpart_ref(counterpart)
    put_node(graph, ref, %{kind: :gstr2b, value: counterpart, entries: [{bucket, entry}]})
  end

  defp put_node(graph, ref, node) do
    nodes =
      Map.update(graph.nodes, ref, node, fn existing ->
        %{existing | entries: Enum.uniq(existing.entries ++ node.entries)}
      end)

    %{graph | nodes: nodes, adjacency: Map.put_new(graph.adjacency, ref, MapSet.new())}
  end

  defp put_edge(graph, nil, _counterpart, _bucket), do: graph
  defp put_edge(graph, _books, nil, _bucket), do: graph

  defp put_edge(graph, books, counterpart, bucket) do
    books_ref = books_ref(books)
    counterpart_ref = counterpart_ref(counterpart)
    edge_key = {books_ref, counterpart_ref}

    adjacency =
      graph.adjacency
      |> Map.update!(books_ref, &MapSet.put(&1, counterpart_ref))
      |> Map.update!(counterpart_ref, &MapSet.put(&1, books_ref))

    edge = %{
      books_ref: books["id"],
      gstr2b_ref: Reconciliation.gstr2b_ref(counterpart),
      bucket: bucket
    }

    %{graph | adjacency: adjacency, edges: Map.put_new(graph.edges, edge_key, edge)}
  end

  defp components(graph) do
    graph.nodes
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce({[], MapSet.new()}, fn ref, {components, seen} ->
      if MapSet.member?(seen, ref) do
        {components, seen}
      else
        component = walk(graph.adjacency, [ref], MapSet.new())
        {[component | components], MapSet.union(seen, component)}
      end
    end)
    |> elem(0)
  end

  defp walk(_adjacency, [], seen), do: seen

  defp walk(adjacency, [ref | rest], seen) do
    if MapSet.member?(seen, ref) do
      walk(adjacency, rest, seen)
    else
      neighbours = adjacency |> Map.fetch!(ref) |> MapSet.to_list()
      walk(adjacency, neighbours ++ rest, MapSet.put(seen, ref))
    end
  end

  defp to_group(graph, component) do
    refs = component |> MapSet.to_list() |> Enum.sort()
    nodes = Enum.map(refs, &Map.fetch!(graph.nodes, &1))

    books =
      nodes
      |> Enum.filter(&(&1.kind == :books))
      |> Enum.map(& &1.value)
      |> Enum.uniq_by(& &1["id"])
      |> Enum.sort_by(fn books -> to_string(books["id"]) end)

    counterparts =
      nodes
      |> Enum.filter(&(&1.kind == :gstr2b))
      |> Enum.map(& &1.value)
      |> Enum.uniq_by(&Reconciliation.gstr2b_ref/1)
      |> Enum.sort_by(&Reconciliation.gstr2b_ref/1)

    edges =
      graph.edges
      |> Enum.filter(fn {{books_ref, counterpart_ref}, _edge} ->
        MapSet.member?(component, books_ref) and MapSet.member?(component, counterpart_ref)
      end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort_by(&{&1.books_ref, &1.gstr2b_ref})

    entries = nodes |> Enum.flat_map(& &1.entries) |> Enum.uniq()
    state = state(entries, books, counterparts)

    %{
      key: key(refs),
      books: books,
      counterparts: counterparts,
      edges: edges,
      code: code(entries, state),
      state: state,
      tax_paise: risk_tax(books, counterparts)
    }
  end

  defp state(entries, books, counterparts) do
    buckets = MapSet.new(entries, &elem(&1, 0))

    cond do
      MapSet.member?(buckets, "needs_human") -> :needs_decision
      counterparts == [] and Enum.any?(entries, &open_books_entry?/1) -> :needs_decision
      books == [] and counterparts != [] -> :awaiting_bill
      true -> :settled
    end
  end

  defp open_books_entry?({"in_books_not_2b", entry}), do: entry["accepted_reason"] == nil
  defp open_books_entry?(_entry), do: false

  defp code(entries, :needs_decision), do: reason_code(entries, "needs_decision")
  defp code(entries, :awaiting_bill), do: reason_code(entries, "missing_in_books")

  defp code(entries, :settled) do
    buckets = MapSet.new(entries, &elem(&1, 0))

    cond do
      MapSet.member?(buckets, "value_mismatch") -> "value_mismatch"
      MapSet.member?(buckets, "matched") -> "matched"
      true -> "accepted_unmatched"
    end
  end

  defp reason_code(entries, fallback) do
    entries
    |> Enum.map(fn {_bucket, entry} -> get_in(entry, ["reason", "code"]) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort()
    |> List.first()
    |> case do
      nil -> fallback
      code -> code
    end
  end

  defp risk_tax(_books, [_ | _] = counterparts) do
    counterparts |> Enum.map(&tax_total/1) |> Enum.sum()
  end

  defp risk_tax(books, []) do
    books |> Enum.map(&tax_total/1) |> Enum.sum()
  end

  defp tax_total(invoice) do
    tax = invoice["tax_paise"] || %{}
    (tax["cgst"] || 0) + (tax["sgst"] || 0) + (tax["igst"] || 0) + (tax["cess"] || 0)
  end

  defp books_ref(books), do: "books:#{books["id"]}"
  defp counterpart_ref(counterpart), do: "gstr2b:#{Reconciliation.gstr2b_ref(counterpart)}"

  defp key(refs) do
    digest =
      refs
      |> Enum.join("\n")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "purchase-review-#{digest}"
  end
end
