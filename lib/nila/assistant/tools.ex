defmodule Nila.Assistant.Tools do
  @moduledoc """
  Read-only tools exposed to the Claude assistant. Org scoping is enforced
  here in the dispatch closure using `scope.current_org.id`; the model never
  sees or passes `org_id`. Tool names are matched against a literal `case`
  to avoid `String.to_atom/1` on attacker-controlled input.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Nila.Accounts.Scope
  alias Nila.Documents.Document
  alias Nila.Repo

  @max_limit 50
  @default_limit 20

  @doc """
  Tool specs in a provider-neutral shape (`name`, `description`, `input_schema`).
  The HTTP layer in `Nila.Assistant` translates this into the wire format the
  configured provider expects (e.g. OpenAI `tools[].function.parameters`).
  """
  def specs do
    [
      %{
        name: "search_documents",
        description:
          "Search ingested documents (bank statements, PDFs, uploads) for the current organization. Returns matching documents with filename, type, processing status and dates. Use this to answer 'show me the statements I uploaded', 'which documents are still pending review', etc.",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{
              type: "string",
              description: "Free-text fragment matched against the filename (case-insensitive)."
            },
            status: %{
              type: "string",
              enum: Document.statuses(),
              description: "Filter by processing status (e.g. uploaded, needs_review, approved)."
            },
            document_type: %{
              type: "string",
              description: "Filter by document type (case-insensitive substring)."
            },
            limit: %{type: "integer", description: "Max rows (default 20, capped at 50)."}
          },
          required: []
        }
      }
    ]
  end

  @doc """
  Dispatch a tool call. `tool_name` is matched against a literal `case` —
  unknown names return `{:error, "unknown tool"}`. Org scoping is read from
  `scope.current_org.id`; the model's input is stripped of any `*_id` keys
  before casting so it cannot poke at scoping.
  """
  def dispatch(%Scope{current_org: nil}, _tool_name, _input), do: {:error, "no current org"}

  def dispatch(%Scope{} = scope, tool_name, input) when is_binary(tool_name) and is_map(input) do
    sanitized = strip_id_keys(input)

    case tool_name do
      "search_documents" -> do_search_documents(scope, sanitized)
      _ -> {:error, "unknown tool"}
    end
  end

  defp strip_id_keys(input) when is_map(input) do
    input
    |> Enum.reject(fn {k, _v} ->
      key = to_string(k)
      key == "org_id" or String.ends_with?(key, "_id")
    end)
    |> Map.new()
  end

  # ---- search_documents -------------------------------------------------

  defp do_search_documents(scope, input) do
    types = %{
      query: :string,
      status: :string,
      document_type: :string,
      limit: :integer
    }

    changeset =
      {%{}, types}
      |> Changeset.cast(input, Map.keys(types))
      |> Changeset.validate_inclusion(:status, Document.statuses())

    case changeset_to_map(changeset) do
      {:ok, params} ->
        limit = clamp_limit(params[:limit])
        org_id = scope.current_org.id

        rows =
          Document
          |> where([d], d.org_id == ^org_id)
          |> maybe_filter_status(params[:status])
          |> maybe_filter_query(params[:query])
          |> maybe_filter_document_type(params[:document_type])
          |> order_by([d], desc: d.inserted_at)
          |> limit(^limit)
          |> Repo.all()

        {:ok, %{results: Enum.map(rows, &serialize_document/1), count: length(rows)}}

      {:error, message} ->
        {:error, message}
    end
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, [d], d.status == ^status)

  defp maybe_filter_query(query, nil), do: query
  defp maybe_filter_query(query, ""), do: query

  defp maybe_filter_query(query, q) do
    like = "%" <> q <> "%"
    where(query, [d], ilike(d.filename, ^like))
  end

  defp maybe_filter_document_type(query, nil), do: query
  defp maybe_filter_document_type(query, ""), do: query

  defp maybe_filter_document_type(query, type) do
    like = "%" <> type <> "%"
    where(query, [d], ilike(d.document_type, ^like))
  end

  # ---- helpers ----------------------------------------------------------

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp_limit(_), do: @default_limit

  defp changeset_to_map(%Changeset{valid?: true, changes: changes}), do: {:ok, changes}

  defp changeset_to_map(%Changeset{valid?: false} = cs) do
    msg =
      cs.errors
      |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
      |> Enum.join("; ")

    {:error, "invalid input — " <> msg}
  end

  @doc "Serialize a document for tool output. JSON-safe."
  def serialize_document(%Document{} = doc) do
    %{
      id: doc.id,
      filename: doc.filename,
      document_type: doc.document_type,
      status: doc.status,
      byte_size: doc.byte_size,
      uploaded_at: Nila.Formatters.format_iso_datetime(doc.inserted_at),
      extracted_at: doc.extracted_at && Nila.Formatters.format_iso_datetime(doc.extracted_at)
    }
  end
end
