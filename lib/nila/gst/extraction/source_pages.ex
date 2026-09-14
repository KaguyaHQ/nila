defmodule Nila.Gst.Extraction.SourcePages do
  @moduledoc "Prepares page images and optional native text for invoice extraction."

  alias Nila.Gst.Extraction.Evidence
  alias Nila.Gst.Extraction.NativeText
  alias Nila.Gst.Extraction.NativeTables

  @max_pages 100
  @max_thumbnail_bytes 10_000_000
  @max_full_image_bytes 100_000_000
  @max_segment_image_bytes 20_000_000
  @max_image_bytes 20_000_000
  @thumbnail_dpi 75
  @thumbnail_quality 70
  @image_extensions %{
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp"
  }

  # Vision remains the default. :text is the explicit Poppler route; :native
  # uses guarded tables on eligible pages and images everywhere else.
  def prepare(kind, bytes, opts) do
    input = Keyword.get(opts, :input, :vision)

    with :ok <- validate_input(kind, input),
         {:ok, source} <- render(bytes, opts) do
      content_type =
        Keyword.get(opts, :content_type) ||
          Evidence.content_type(Keyword.get(opts, :filename, "document.pdf"))

      case {input, content_type} do
        {:text, "application/pdf"} ->
          with {:ok, text} <- NativeText.extract(bytes, source.page_count) do
            {:ok, Map.put(source, :native_text, text)}
          end

        {:native, "application/pdf"} ->
          case NativeTables.extract(bytes, source.page_count) do
            {:ok, text, reasons} ->
              {:ok, Map.merge(source, %{native_text: text, native_fallbacks: reasons})}

            {:error, reason} ->
              {:ok,
               Map.merge(source, %{
                 native_text: %{},
                 native_fallbacks: %{"document" => inspect(reason)}
               })}
          end

        _ ->
          {:ok, Map.put(source, :native_text, %{})}
      end
    end
  end

  def text_page?(source, page) do
    source.native_text |> Map.get(page, "") |> String.trim() != ""
  end

  def input_metadata(source) do
    %{
      "native_text" =>
        Map.new(source.native_text, fn {page, text} -> {to_string(page), text} end),
      "text_pages" => Enum.filter(1..source.page_count, &text_page?(source, &1)),
      "native_fallbacks" => Map.get(source, :native_fallbacks, %{})
    }
  end

  def validate_segment_images(images, segment) do
    image_bytes =
      segment.pages
      |> Enum.map(&(images |> Map.fetch!(&1) |> Map.fetch!(:bytes)))
      |> Enum.map(&byte_size/1)
      |> Enum.sum()

    if image_bytes > @max_segment_image_bytes,
      do:
        {:error,
         {:vision_segment_too_large, segment.pages, image_bytes, @max_segment_image_bytes}},
      else: :ok
  end

  def invoice_inputs(source, pages) do
    # A scanned continuation requires images for the entire invoice.
    modality = if Enum.all?(pages, &text_page?(source, &1)), do: :text, else: :vision

    inputs =
      Enum.map(pages, fn page ->
        content =
          if modality == :text,
            do: Map.fetch!(source.native_text, page),
            else: Map.fetch!(source.full, page)

        {page, content}
      end)

    {modality, inputs}
  end

  defp validate_input(_kind, :vision), do: :ok
  defp validate_input(:sales, :text), do: :ok
  defp validate_input(:sales, :native), do: :ok
  defp validate_input(kind, input), do: {:error, {:unsupported_extraction_input, kind, input}}

  defp render(bytes, opts) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type) || Evidence.content_type(filename)

    cond do
      content_type == "application/pdf" ->
        with {:ok, thumbnails} <-
               Evidence.render_pages(
                 bytes,
                 opts
                 |> Keyword.put(:dpi, @thumbnail_dpi)
                 |> Keyword.put(:jpeg_quality, @thumbnail_quality)
                 |> Keyword.put(:last_page, @max_pages + 1)
               ),
             :ok <- validate_packet(thumbnails),
             {:ok, evidence} <- Evidence.render_pages(bytes, opts),
             :ok <- validate_full_images(evidence) do
          {:ok,
           %{
             full: pdf_pages(evidence),
             thumbnails: pdf_pages(thumbnails),
             evidence: evidence,
             page_count: map_size(evidence)
           }}
        end

      extension = @image_extensions[content_type] ->
        if byte_size(bytes) <= @max_image_bytes do
          basename = "page_01.#{extension}"
          page = %{bytes: bytes, content_type: content_type, basename: basename}

          {:ok,
           %{
             full: %{1 => page},
             thumbnails: %{1 => page},
             evidence: %{basename => bytes},
             page_count: 1
           }}
        else
          {:error, {:vision_image_too_large, byte_size(bytes), @max_image_bytes}}
        end

      true ->
        {:error, {:unsupported_content_type, content_type}}
    end
  end

  defp validate_packet(images) do
    page_count = map_size(images)
    image_bytes = images |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    cond do
      page_count == 0 ->
        {:error, :vision_packet_has_no_pages}

      page_count > @max_pages ->
        {:error, {:vision_packet_too_many_pages, page_count, @max_pages}}

      image_bytes > @max_thumbnail_bytes ->
        {:error, {:vision_packet_too_large, image_bytes, @max_thumbnail_bytes}}

      true ->
        :ok
    end
  end

  defp validate_full_images(images) do
    image_bytes = images |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    if image_bytes > @max_full_image_bytes,
      do: {:error, {:vision_render_too_large, image_bytes, @max_full_image_bytes}},
      else: :ok
  end

  defp pdf_pages(images) do
    Map.new(images, fn {basename, bytes} ->
      [number] = Regex.run(~r/page_(\d+)\.jpg$/, basename, capture: :all_but_first)

      {String.to_integer(number), %{bytes: bytes, content_type: "image/jpeg", basename: basename}}
    end)
  end
end
