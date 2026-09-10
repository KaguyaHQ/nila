defmodule Nila.Gst.Extraction.InvoiceRequest do
  @moduledoc """
  Builds the messages and schema sent for one invoice; performs no IO.

  InvoicePrompt owns reading instructions; InvoiceSchema owns fields, ordering
  and response shapes. Pipelines and evaluations use these same builders.
  Classification and downstream verification are separate from this request.
  """

  alias Nila.Gst.Extraction.{InvoicePrompt, InvoiceSchema}

  @doc "Builds an invoice request from ordered {physical_page, text_or_image} pairs."
  def build(kind, pages, modality) when modality in [:text, :vision] do
    instruction = InvoicePrompt.build(kind, Enum.map(pages, &elem(&1, 0)), modality)

    content =
      [%{type: "text", text: instruction}] ++ Enum.flat_map(pages, &page_parts(&1, modality))

    %{
      name: "nila_#{kind}_invoice",
      schema: InvoiceSchema.tuple_schema(kind),
      messages: [
        %{role: "system", content: InvoicePrompt.system(modality)},
        %{role: "user", content: content}
      ]
    }
  end

  defp page_parts({page, text}, :text),
    do: [%{type: "text", text: "PHYSICAL PAGE #{page}\n" <> text}]

  defp page_parts({page, image}, :vision) do
    [
      %{type: "text", text: "PHYSICAL PAGE #{page}"},
      %{
        type: "image_url",
        image_url: %{url: "data:#{image.content_type};base64," <> Base.encode64(image.bytes)}
      }
    ]
  end
end
