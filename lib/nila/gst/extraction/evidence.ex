defmodule Nila.Gst.Extraction.Evidence do
  @moduledoc """
  Renders a packet into page images and binds extracted artifacts to them.

  Rendering is independent of extraction: the segmented pipeline attaches
  evidence after reading a packet, and the backfill rebuilds the same images
  from stored originals without asking a provider to extract them again.
  """

  alias Nila.Gst.Extraction.Providers.Mistral

  require Logger

  # A packet is photographs of paper, and PNG is a lossless format built for
  # flat colour — the wrong pair. The pages already sit inside the PDF as 200
  # DPI JPEGs; rendering them back out as PNG at that same resolution bought no
  # detail and cost 5.8x the bytes (2,136 KB against 371 KB on a real month),
  # every one of which crossed the wire again each time a reviewer stepped to
  # the next bill. Poppler's default quality lands within 200 bytes of the
  # JPEG the scanner produced, so this is the same picture, not a smaller one.
  #
  # Format lives here alone: the basename carries the extension, storage keys
  # are per artifact, and both evidence controllers already serve png, jpeg and
  # webp — so moving again is this constant and the render flag.
  @render_format "jpeg"
  @render_quality 75
  @render_dpi 200
  @extension "jpg"

  @doc """
  Renders the packet and points each artifact at its first attributed page.

  A render failure does not discard successfully extracted invoices. It adds
  `:evidence_error` so intake can flag the missing review evidence.
  """
  def attach(result, bytes, opts) do
    case render_pages(bytes, opts) do
      {:ok, images} ->
        %{result | images: images, pages: Enum.map(result.pages, &put_image(&1, images))}

      {:error, reason} ->
        Logger.warning("extraction.evidence_render_failed reason=#{inspect(reason)}")
        Map.put(result, :evidence_error, reason)
    end
  end

  defp put_image(artifact, images) do
    with [page | _rest] <- artifact["source_pages"],
         basename = page_basename(page),
         true <- is_map_key(images, basename) do
      Map.put(artifact, "image", basename)
    else
      _no_page -> Map.put(artifact, "image", nil)
    end
  end

  @doc """
  Renders a PDF to page images keyed by stable page basenames.

  Images return an empty map because the uploaded image is already its own
  evidence and needs no PDF rasterization.
  """
  @spec render_pages(binary(), keyword()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def render_pages(bytes, opts \\ []) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type) || Mistral.content_type(filename)

    if content_type == "application/pdf" do
      rasterize(
        bytes,
        Keyword.get(opts, :dpi, @render_dpi),
        Keyword.get(opts, :jpeg_quality, @render_quality),
        Keyword.get(opts, :last_page)
      )
    else
      {:ok, %{}}
    end
  end

  defp rasterize(bytes, dpi, quality, last_page) do
    dir = Path.join(System.tmp_dir!(), "nila_render_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      pdf_path = Path.join(dir, "source.pdf")
      File.write!(pdf_path, bytes)

      args =
        [
          "-#{@render_format}",
          "-jpegopt",
          "quality=#{quality}",
          "-r",
          to_string(dpi)
        ] ++
          last_page_args(last_page) ++
          [pdf_path, Path.join(dir, "page")]

      case System.cmd(pdftocairo(), args, stderr_to_stdout: true) do
        {_output, 0} -> {:ok, read_rendered(dir)}
        {output, status} -> {:error, {:page_render_failed, status, String.trim(output)}}
      end
    rescue
      error -> {:error, {:page_render_failed, Exception.message(error)}}
    after
      File.rm_rf(dir)
    end
  end

  defp last_page_args(last_page) when is_integer(last_page) and last_page > 0,
    do: ["-f", "1", "-l", to_string(last_page)]

  defp last_page_args(_last_page), do: []

  defp read_rendered(dir) do
    dir
    |> Path.join("page-*.#{@extension}")
    |> normalize_glob_path()
    |> Path.wildcard()
    |> Map.new(fn path ->
      [number] = Regex.run(~r/page-(\d+)\.#{@extension}$/, path, capture: :all_but_first)
      {number |> String.to_integer() |> page_basename(), File.read!(path)}
    end)
  end

  # `System.tmp_dir!/0` uses backslashes on Windows while `Path.join/2` adds a
  # forward slash. Erlang's Windows glob implementation treats that mixed path
  # as no matches even though Poppler wrote the pages successfully.
  defp normalize_glob_path(path), do: String.replace(path, "\\", "/")

  @doc "The stable evidence basename for a 1-based page number."
  @spec page_basename(pos_integer()) :: String.t()
  def page_basename(page),
    do: "page_#{String.pad_leading(to_string(page), 2, "0")}.#{@extension}"

  defp pdftocairo, do: Application.get_env(:nila, __MODULE__, [])[:pdftocairo] || "pdftocairo"
end
