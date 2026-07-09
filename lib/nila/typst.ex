defmodule Nila.Typst do
  @moduledoc """
  Renders documents to PDF with the Typst typesetting engine.

  The engine is a single static binary (`typst`) invoked per render — no
  long-running process, no pool to supervise. We hand it a presentational
  template (`priv/typst/<name>.typ`, which must define `#let main(data) = {…}`)
  plus a JSON blob of *already-formatted* values, and it lays out an A4 PDF.

  All money/date/number formatting stays in Elixir (`Nila.Formatters`,
  `Nila.Gst`) so the on-screen document and this PDF can never disagree on a
  value; the template only positions text. That is the whole reason the data is
  the single source of truth and the `.typ` file is pure layout.

  Glyph coverage (₹, Tamil) depends on installed fonts. macOS dev picks them up
  from the system; the production image must ship a font that covers them (Noto)
  or drop one into `priv/typst/fonts/`, which is added to the font path here.
  """

  require Logger

  @doc """
  Renders `template` (a name under `priv/typst/`, without the `.typ` suffix)
  against `data`, returning the PDF bytes.

  `data` is JSON-encoded and exposed to the template as `json("data.json")`.

  `opts[:assets]` is a list of `{relative_name, source_path}` files (e.g.
  scan images) copied beside the template so `image(relative_name)` resolves.
  """
  def render(template, data, opts \\ []) do
    with {:ok, bin} <- executable(),
         {:ok, json} <- encode(data) do
      in_tmp_dir(fn dir ->
        File.write!(Path.join(dir, "data.json"), json)
        copy_partials(dir)
        copy_assets(dir, Keyword.get(opts, :assets, []))
        File.write!(Path.join(dir, "entry.typ"), entry_source(template))
        compile(bin, dir)
      end)
    end
  end

  defp copy_assets(dir, assets) do
    Enum.each(assets, fn {name, source} ->
      dest = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(source, dest)
    end)
  end

  defp entry_source(template) do
    source = File.read!(template_path(template))
    source <> "\n\n#main(json(\"data.json\"))\n"
  end

  # Underscore-prefixed files in priv/typst are shared layout partials
  # (`#import "_shared.typ"`); they must sit next to entry.typ to resolve.
  defp copy_partials(dir) do
    [:code.priv_dir(:nila), "typst", "_*.typ"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.each(&File.cp!(&1, Path.join(dir, Path.basename(&1))))
  end

  defp compile(bin, dir) do
    out = Path.join(dir, "out.pdf")

    args =
      ["compile", "--root", dir, Path.join(dir, "entry.typ"), out] ++ font_args()

    case System.cmd(bin, args, stderr_to_stdout: true) do
      {_, 0} ->
        File.read(out)

      {output, code} ->
        Logger.error("typst compile failed (#{code}): #{output}")
        {:error, {:typst_failed, code, output}}
    end
  end

  defp in_tmp_dir(fun) do
    dir = Path.join(System.tmp_dir!(), "nila-typst-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      fun.(dir)
    after
      File.rm_rf(dir)
    end
  end

  defp encode(data) do
    case Jason.encode(data) do
      {:ok, json} -> {:ok, json}
      {:error, reason} -> {:error, {:json_encode, reason}}
    end
  end

  defp executable do
    case System.find_executable(config(:bin, "typst")) do
      nil -> {:error, :typst_not_found}
      bin -> {:ok, bin}
    end
  end

  defp font_args do
    dir = Path.join(:code.priv_dir(:nila), "typst/fonts")
    if File.dir?(dir), do: ["--font-path", dir], else: []
  end

  defp template_path(template),
    do: Path.join([:code.priv_dir(:nila), "typst", "#{template}.typ"])

  defp config(key, default),
    do: :nila |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
end
