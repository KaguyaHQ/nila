defmodule Nila.Business.Pdf do
  @moduledoc "Renders server-calculated draft or issued snapshots with the bundled Typst template."

  @timeout 15_000
  @max_pdf_bytes 10_000_000

  def render(snapshot) when is_map(snapshot) do
    config = Application.get_env(:nila, __MODULE__, [])
    bin = Keyword.get(config, :bin, System.get_env("TYPST_BIN") || "typst")

    case System.find_executable(bin) do
      nil ->
        {:error, :pdf_renderer_unavailable}

      executable ->
        render_in_directory(executable, snapshot, Keyword.get(config, :timeout, @timeout))
    end
  end

  def render(_), do: {:error, :invalid_invoice_snapshot}

  defp render_in_directory(executable, snapshot, timeout) do
    dir = Path.join(System.tmp_dir!(), "nila-business-pdf-#{Ecto.UUID.generate()}")

    try do
      File.mkdir_p!(dir)
      template = Application.app_dir(:nila, "priv/business/invoice.typ")
      fonts = Application.app_dir(:nila, "priv/business/fonts")
      source = Path.join(dir, "invoice.typ")
      output = Path.join(dir, "invoice.pdf")
      File.cp!(template, source)

      args = [
        "compile",
        "--root",
        dir,
        "--font-path",
        fonts,
        "--ignore-system-fonts",
        source,
        output
      ]

      with {:ok, branded} <- materialize_brand_assets(dir, snapshot),
           :ok <- File.write(Path.join(dir, "invoice.json"), Jason.encode!(presentation(branded))),
           :ok <- compile(executable, args, timeout),
           {:ok, %{size: size}} when size <= @max_pdf_bytes <- File.stat(output),
           {:ok, <<"%PDF-", _::binary>> = bytes} <- File.read(output) do
        {:ok, bytes}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_pdf_output}
      end
    rescue
      _error in [KeyError, ArgumentError, Protocol.UndefinedError] ->
        {:error, :invalid_invoice_snapshot}

      _error in [File.Error, ErlangError] ->
        {:error, :pdf_render_failed}
    after
      File.rm_rf(dir)
    end
  end

  defp materialize_brand_assets(dir, snapshot) do
    supplier = Map.fetch!(snapshot, "supplier")

    Enum.reduce_while(
      [{"logo_key", "logo_file"}, {"signature_key", "signature_file"}],
      {:ok, supplier},
      fn {key_name, file_name}, {:ok, current} ->
        case supplier[key_name] do
          nil ->
            {:cont, {:ok, current}}

          key ->
            extension = if String.ends_with?(key, ".png"), do: ".png", else: ".jpg"
            filename = file_name <> extension

            with {:ok, bytes} <- Nila.Storage.get(key),
                 :ok <- File.write(Path.join(dir, filename), bytes) do
              {:cont, {:ok, Map.put(current, file_name, filename)}}
            else
              _ -> {:halt, {:error, :pdf_render_failed}}
            end
        end
      end
    )
    |> case do
      {:ok, branded_supplier} -> {:ok, Map.put(snapshot, "supplier", branded_supplier)}
      error -> error
    end
  end

  # Decimal display inputs remain strings; all amounts come from Phoenix's
  # integer-paise snapshot. Typst never recalculates tax or invoice totals.
  defp presentation(snapshot) do
    lines =
      Enum.map(Map.fetch!(snapshot, "lines"), fn line ->
        line
        |> Map.put("rate_display", decimal_money(Map.fetch!(line, "unit_price")))
        |> Map.put("taxable_display", money(Map.fetch!(line, "taxable_paise")))
      end)

    totals = Map.fetch!(snapshot, "totals")

    tax_rows =
      Enum.flat_map(
        [{"CGST", "cgst_paise"}, {"SGST", "sgst_paise"}, {"IGST", "igst_paise"}],
        fn {label, key} ->
          case Map.fetch!(totals, key) do
            0 -> []
            amount -> [%{"label" => label, "amount" => money(amount)}]
          end
        end
      )

    snapshot
    |> Map.put("lines", lines)
    |> Map.put("tax_rows", tax_rows)
    |> Map.put("subtotal_display", money(Map.fetch!(totals, "taxable_paise")))
    |> Map.put("total_display", money(Map.fetch!(totals, "total_paise")))
    |> Map.put("invoice_date_display", display_date(Map.fetch!(snapshot, "invoice_date")))
    |> Map.put("valid_until_display", display_date(snapshot["valid_until"]))
    |> Map.put("due_date_display", display_date(snapshot["due_date"]))
    |> Map.put("purchase_order_date_display", display_date(snapshot["purchase_order_date"]))
    |> Map.put("original_invoice_date_display", display_date(snapshot["original_invoice_date"]))
    |> Map.put("place_of_supply_display", state(Map.fetch!(snapshot, "place_of_supply")))
    |> Map.put("delivery_state_display", state(snapshot["delivery_state_code"]))
  end

  defp display_date(nil), do: nil
  defp display_date(""), do: nil

  defp display_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Calendar.strftime(date, "%-d %b %Y")
      _ -> value
    end
  end

  defp decimal_money(value) do
    value
    |> Decimal.new()
    |> Decimal.mult(100)
    |> Decimal.round(0)
    |> Decimal.to_integer()
    |> money()
  end

  defp money(paise) when is_integer(paise) do
    digits = Integer.to_string(div(abs(paise), 100))

    grouped =
      if String.length(digits) > 3 do
        {head, tail} = String.split_at(digits, -3)
        String.replace(head, ~r/\B(?=(\d{2})+(?!\d))/, ",") <> "," <> tail
      else
        digits
      end

    sign = if paise < 0, do: "-", else: ""

    sign <>
      "₹" <> grouped <> "." <> String.pad_leading(Integer.to_string(rem(abs(paise), 100)), 2, "0")
  end

  defp state(code) do
    case Nila.Gst.StateCodes.name_for(code) do
      nil -> code
      name -> "#{name} (#{code})"
    end
  end

  defp compile(executable, args, timeout) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        args: Enum.map(args, &String.to_charlist/1)
      ])

    try do
      await_exit(port, System.monotonic_time(:millisecond) + timeout)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp await_exit(port, deadline) do
    receive do
      {^port, {:data, _diagnostic}} -> await_exit(port, deadline)
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, _}} -> {:error, :pdf_render_failed}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        terminate(port)
        {:error, :pdf_render_timeout}
    end
  end

  defp terminate(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        case :os.type() do
          {:win32, _} ->
            System.cmd("taskkill", ["/PID", to_string(pid), "/T", "/F"], stderr_to_stdout: true)

          _ ->
            System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
        end

      nil ->
        :ok
    end
  end
end
