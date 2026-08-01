defmodule Nila.Gst.Extraction.Evidence do
  @moduledoc """
  Renders a packet into page images and binds extracted artifacts to them.

  Rendering is independent of extraction: the segmented pipeline attaches
  evidence after reading a packet, and the backfill rebuilds the same images
  from stored originals without asking a provider to extract them again.
  """

  alias Nila.Gst.Extraction.Providers.Mistral

  require Logger

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
  Renders a PDF to PNG images keyed by stable page basenames.

  Images return an empty map because the uploaded image is already its own
  evidence and needs no PDF rasterization.
  """
  @spec render_pages(binary(), keyword()) :: {:ok, %{String.t() => binary()}} | {:error, term()}
  def render_pages(bytes, opts \\ []) do
    filename = Keyword.get(opts, :filename, "document.pdf")
    content_type = Keyword.get(opts, :content_type) || Mistral.content_type(filename)

    if content_type == "application/pdf", do: rasterize(bytes), else: {:ok, %{}}
  end

  defp rasterize(bytes) do
    dir = Path.join(System.tmp_dir!(), "nila_render_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      pdf_path = Path.join(dir, "source.pdf")
      File.write!(pdf_path, bytes)

      case System.cmd(pdftocairo(), ["-png", "-r", "200", pdf_path, Path.join(dir, "page")],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> {:ok, read_rendered(dir)}
        {output, status} -> {:error, {:page_render_failed, status, String.trim(output)}}
      end
    rescue
      error -> {:error, {:page_render_failed, Exception.message(error)}}
    after
      File.rm_rf(dir)
    end
  end

  defp read_rendered(dir) do
    dir
    |> Path.join("page-*.png")
    |> Path.wildcard()
    |> Map.new(fn path ->
      [number] = Regex.run(~r/page-(\d+)\.png$/, path, capture: :all_but_first)
      {number |> String.to_integer() |> page_basename(), File.read!(path)}
    end)
  end

  @doc "The stable evidence basename for a 1-based page number."
  @spec page_basename(pos_integer()) :: String.t()
  def page_basename(page), do: "page_#{String.pad_leading(to_string(page), 2, "0")}.png"

  defp pdftocairo, do: Application.get_env(:nila, __MODULE__, [])[:pdftocairo] || "pdftocairo"
end
