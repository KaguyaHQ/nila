defmodule PackBuildScript do
  @moduledoc false

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [register_dir: :string, books: :string, corrections: :string,
                 filed_3b: :string, entity_name: :string, gstin: :string,
                 address: :string, period: :string, out: :string]
      )

    register_dir = Path.expand(req!(opts, :register_dir))
    books_dir = Path.dirname(Path.expand(req!(opts, :books)))
    period = req!(opts, :period)

    rows =
      register_dir |> Path.join("register_rows.json") |> File.read!() |> Jason.decode!()

    recon = register_dir |> Path.join("recon.json") |> File.read!() |> Jason.decode!()

    corrections =
      case opts[:corrections] do
        nil -> []
        path -> path |> File.read!() |> Jason.decode!() |> Map.fetch!("corrections")
      end

    filed_3b =
      case opts[:filed_3b] do
        nil -> nil
        path -> path |> File.read!() |> Jason.decode!()
      end

    meta = %{
      "entity" => req!(opts, :entity_name),
      "gstin" => req!(opts, :gstin),
      "address" => opts[:address] || "",
      "period" => period,
      "prepared_on" => Date.utc_today() |> Calendar.strftime("%d-%m-%Y")
    }

    pack = Nila.Gst.MonthPack.build(rows, recon, corrections, meta, filed_3b)

    jpg_dir = Path.join(System.tmp_dir!(), "pack-jpg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(jpg_dir)

    {pack, assets} = compress_appendix(pack, books_dir, jpg_dir)

    out = Path.expand(opts[:out] || Path.join(register_dir, "month_pack_#{period}.pdf"))

    case Nila.Typst.render("month_pack", pack, assets: assets) do
      {:ok, pdf} ->
        File.write!(out, pdf)
        IO.puts("wrote #{out} (#{byte_size(pdf)} bytes, #{length(assets)} evidence images)")

      {:error, reason} ->
        Mix.raise("pack render failed: #{inspect(reason)}")
    end
  end

  defp req!(opts, key), do: opts[key] || Mix.raise("--#{key} is required")

  defp compress_appendix(pack, books_dir, jpg_dir) do
    mapping =
      pack["appendix"]
      |> Enum.flat_map(& &1["images"])
      |> Enum.uniq()
      |> Enum.flat_map(fn rel ->
        src = Path.join(books_dir, rel)

        if File.exists?(src) do
          jpg_rel = Path.rootname(rel) <> ".jpg"
          out = Path.join(jpg_dir, Path.basename(jpg_rel))

          {_, 0} =
            System.cmd(
              "sips",
              ["-s", "format", "jpeg", "-s", "formatOptions", "70",
               "--resampleWidth", "1400", src, "--out", out],
              stderr_to_stdout: true
            )

          [{rel, {jpg_rel, out}}]
        else
          []
        end
      end)
      |> Map.new()

    appendix =
      Enum.map(pack["appendix"], fn item ->
        Map.update!(item, "images", fn images ->
          Enum.map(images, fn rel ->
            case mapping[rel] do
              {jpg_rel, _} -> jpg_rel
              nil -> rel
            end
          end)
        end)
      end)

    assets = Enum.map(mapping, fn {_rel, {jpg_rel, out}} -> {jpg_rel, out} end)
    {Map.put(pack, "appendix", appendix), assets}
  end
end

PackBuildScript.run(System.argv())
