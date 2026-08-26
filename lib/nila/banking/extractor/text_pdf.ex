defmodule Nila.Banking.Extractor.TextPdf do
  @moduledoc """
  Extracts a bank-generated PDF's embedded text with Poppler and dispatches it
  to the matching bank's deterministic layout parser. Scans are deliberately
  rejected; this path never invokes OCR.
  """

  @behaviour Nila.Banking.Extractor

  alias Nila.Banking.Parsers.{Hdfc, HdfcV2, Iob, Kotak, KotakLegacy}

  @parsers [Hdfc, Kotak, Iob, KotakLegacy, HdfcV2]

  @impl true
  def extract(bytes, opts) when is_binary(bytes) do
    password = Keyword.get(opts, :password)

    with :ok <- pdf?(bytes) do
      extract_pdf(bytes, password)
    end
  end

  defp extract_pdf(bytes, password) do
    path = Path.join(System.tmp_dir!(), "nila-bank-#{Ecto.UUID.generate()}.pdf")

    try do
      with :ok <- File.write(path, bytes),
           {:ok, text} <- extract_text(path, password, "-layout"),
           :ok <- usable_text?(text) do
        case parse_text(text) do
          {:error, :unsupported_statement} -> parse_mode(path, password, :raw)
          result -> result
        end
      end
    after
      File.rm(path)
    end
  rescue
    ErlangError -> {:error, :text_extraction_unavailable}
  end

  @doc false
  def parse_text(text) when is_binary(text) do
    dispatch(text, :layout)
  end

  defp parse_mode(path, password, mode) do
    with {:ok, text} <- extract_text(path, password, mode_arg(mode)),
         :ok <- usable_text?(text) do
      dispatch(text, mode)
    end
  end

  defp dispatch(text, mode) do
    @parsers
    |> Enum.filter(&(&1.text_mode() == mode))
    |> Enum.reduce_while({:error, :unsupported_statement}, fn parser, _result ->
      case parser.parse(text) do
        {:error, :unsupported_statement} = unsupported -> {:cont, unsupported}
        result -> {:halt, result}
      end
    end)
  end

  defp mode_arg(:layout), do: "-layout"
  defp mode_arg(:raw), do: "-raw"

  defp pdf?(<<"%PDF-", _rest::binary>>), do: :ok
  defp pdf?(_bytes), do: {:error, :not_text_pdf}

  defp usable_text?(text) do
    if String.length(String.trim(text)) >= 100,
      do: :ok,
      else: {:error, :not_text_pdf}
  end

  defp extract_text(path, password, mode) do
    case run_pdftotext(path, password, "-upw", mode) do
      {:error, :password_required} when is_binary(password) ->
        run_pdftotext(path, password, "-opw", mode)

      result ->
        result
    end
  end

  defp run_pdftotext(path, password, password_slot, mode) do
    password_args =
      case password do
        value when is_binary(value) and value != "" -> [password_slot, value]
        _missing -> []
      end

    args = [mode, "-enc", "UTF-8"] ++ password_args ++ [path, "-"]
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
