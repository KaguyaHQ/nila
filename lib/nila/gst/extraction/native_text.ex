defmodule Nila.Gst.Extraction.NativeText do
  @moduledoc """
  Reads a PDF's existing text with Poppler, preserving physical page boundaries.

  This does not certify an OCR layer or infer invoice fields. Callers explicitly
  select native text for known digital sources; empty pages remain available to vision.
  """

  @max_text_bytes 2_000_000

  def extract(bytes, page_count) when is_binary(bytes) and page_count > 0 do
    dir = Path.join(System.tmp_dir!(), "nila-native-text-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)

    try do
      source = Path.join(dir, "source.pdf")
      output = Path.join(dir, "text.txt")
      File.write!(source, bytes)

      # Write text separately so Poppler diagnostics can never become invoice evidence.
      case System.cmd("pdftotext", ["-layout", "-enc", "UTF-8", source, output],
             stderr_to_stdout: true
           ) do
        {_diagnostic, 0} ->
          with {:ok, %{size: size}} when size <= @max_text_bytes <- File.stat(output),
               {:ok, text} <- File.read(output) do
            pages(text, page_count)
          else
            {:ok, _stat} -> {:error, :native_text_too_large}
            {:error, reason} -> {:error, {:native_text_read_failed, reason}}
          end

        {diagnostic, status} ->
          {:error, {:native_text_failed, status, String.slice(diagnostic, 0, 500)}}
      end
    after
      File.rm_rf(dir)
    end
  rescue
    error in [ErlangError, File.Error] ->
      {:error, {:native_text_unavailable, Exception.message(error)}}
  end

  defp pages(text, expected_count) do
    if String.valid?(text) do
      # Poppler terminates each page with form feed, including blank pages.
      text =
        if String.ends_with?(text, "\f"),
          do: binary_part(text, 0, byte_size(text) - 1),
          else: text

      pages = String.split(text, "\f", trim: false)

      if length(pages) == expected_count do
        {:ok, pages |> Enum.with_index(1) |> Map.new(fn {text, page} -> {page, text} end)}
      else
        {:error, {:native_text_page_count, expected_count, length(pages)}}
      end
    else
      {:error, :native_text_invalid_encoding}
    end
  end
end
