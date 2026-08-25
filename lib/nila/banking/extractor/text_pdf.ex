defmodule Nila.Banking.Extractor.TextPdf do
  @moduledoc """
  Extracts a bank-generated PDF's embedded text with Poppler and dispatches it
  to the matching bank's deterministic layout parser. Scans are deliberately
  rejected; this path never invokes OCR.
  """

  @behaviour Nila.Banking.Extractor

  alias Nila.Banking.Parsers.Hdfc
  alias Nila.Banking.Parsers.Kotak

  @impl true
  def extract(bytes, opts) when is_binary(bytes) do
    password = Keyword.get(opts, :password)

    with :ok <- pdf?(bytes),
         {:ok, text} <- text(bytes, password),
         :ok <- usable_text?(text) do
      parse_text(text)
    end
  end

  defp text(bytes, password) do
    path = Path.join(System.tmp_dir!(), "nila-bank-#{Ecto.UUID.generate()}.pdf")

    try do
      with :ok <- File.write(path, bytes) do
        extract_text(path, password)
      end
    after
      File.rm(path)
    end
  rescue
    ErlangError -> {:error, :text_extraction_unavailable}
  end

  @doc false
  def parse_text(text) when is_binary(text) do
    case Hdfc.parse(text) do
      {:error, :unsupported_statement} -> Kotak.parse(text)
      result -> result
    end
  end

  defp pdf?(<<"%PDF-", _rest::binary>>), do: :ok
  defp pdf?(_bytes), do: {:error, :not_text_pdf}

  defp usable_text?(text) do
    if String.length(String.trim(text)) >= 100,
      do: :ok,
      else: {:error, :not_text_pdf}
  end

  defp extract_text(path, password) do
    case run_pdftotext(path, password, "-upw") do
      {:error, :password_required} when is_binary(password) ->
        run_pdftotext(path, password, "-opw")

      result ->
        result
    end
  end

  defp run_pdftotext(path, password, password_slot) do
    password_args =
      case password do
        value when is_binary(value) and value != "" -> [password_slot, value]
        _missing -> []
      end

    args = ["-layout", "-enc", "UTF-8"] ++ password_args ++ [path, "-"]
    {output, status} = System.cmd("pdftotext", args, stderr_to_stdout: true)

    case status do
      0 -> {:ok, output}
      _ -> {:error, pdf_error(output)}
    end
  end

  defp pdf_error(output) do
    if String.match?(output, ~r/(password|encrypted)/i),
      do: :password_required,
      else: :not_text_pdf
  end
end
