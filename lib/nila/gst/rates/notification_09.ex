defmodule Nila.Gst.Rates.Notification09 do
  @moduledoc "Parses the schedules in Notification 09/2025-Integrated Tax (Rate)."

  @expected_counts %{
    "I" => 516,
    "II" => 640,
    "III" => 13,
    "IV" => 15,
    "V" => 3,
    "VI" => 2,
    "VII" => 6
  }

  @condition_pattern ~r/\bother than\b|\bexcept\b|pre[ -]packaged|labelled|intended for|used in|for use|subject to|provided that|\bif\b|\bwhen\b|specified in|not elsewhere|not otherwise|solely|of a kind/i

  def extract(path) do
    with executable when is_binary(executable) <- System.find_executable("pdftotext"),
         {text, 0} <- System.cmd(executable, ["-layout", path, "-"]) do
      parse(text)
    else
      nil -> {:error, :pdftotext_not_found}
      {_output, status} -> {:error, {:pdftotext_failed, status}}
    end
  end

  def parse(text) when is_binary(text) do
    with {:ok, metadata} <- metadata(text),
         {:ok, rules} <- parse_rules(text),
         :ok <- validate_counts(rules) do
      {:ok, %{metadata: metadata, rules: rules}}
    end
  end

  defp metadata(text) do
    with [_, number] <-
           Regex.run(~r/NO\.\s*(\d+\/\d+)-Integrated Tax \(Rate\)/i, text),
         [_, published] <-
           Regex.run(~r/New Delhi, the (\d{1,2}(?:st|nd|rd|th) \w+,? \d{4})/i, text),
         [_, effective] <-
           Regex.run(
             ~r/come into force with effect from the (\d{1,2}(?:st|nd|rd|th) day of \w+,? \d{4})/i,
             text
           ),
         {:ok, published_on} <- parse_date(published),
         {:ok, effective_from} <- parse_date(effective) do
      {:ok,
       %{
         notification_number: "#{number}-Integrated Tax (Rate)",
         tax_type: "integrated",
         published_on: published_on,
         effective_from: effective_from
       }}
    else
      _ -> {:error, :unsupported_notification}
    end
  end

  defp parse_date(value) do
    normalized =
      value
      |> String.replace(~r/(\d)(?:st|nd|rd|th)/i, "\\1")
      |> String.replace(" day of ", " ")
      |> String.replace(",", "")

    case String.split(normalized, " ", trim: true) do
      [day, month, year] ->
        with {:ok, month} <- month_number(month),
             {day, ""} <- Integer.parse(day),
             {year, ""} <- Integer.parse(year) do
          Date.new(year, month, day)
        end

      _ ->
        {:error, :invalid_date}
    end
  end

  defp month_number(month) do
    months =
      ~w(January February March April May June July August September October November December)

    case Enum.find_index(months, &(String.downcase(&1) == String.downcase(month))) do
      nil -> {:error, :invalid_month}
      index -> {:ok, index + 1}
    end
  end

  defp parse_rules(text) do
    state =
      text
      |> String.split("\n")
      |> Enum.reduce(initial_state(), &parse_line/2)
      |> finalize_current()

    case state.error do
      nil -> {:ok, Enum.reverse(state.rules)}
      reason -> {:error, reason}
    end
  end

  defp initial_state do
    %{schedule: nil, rate: nil, next_serial: nil, current: nil, rules: [], error: nil}
  end

  defp parse_line(_line, %{error: error} = state) when not is_nil(error), do: state

  defp parse_line(line, state) do
    cond do
      schedule = schedule_heading(line) ->
        state
        |> finalize_current()
        |> Map.merge(%{
          schedule: schedule.name,
          rate: Decimal.new(schedule.rate),
          next_serial: 1,
          current: nil
        })

      stop_notification_explanation?(line, state) ->
        state |> finalize_current() |> Map.merge(%{schedule: nil, rate: nil, next_serial: nil})

      is_nil(state.schedule) or skip_line?(line) ->
        state

      true ->
        parse_schedule_line(line, state)
    end
  end

  defp schedule_heading(line) do
    case Regex.run(
           ~r/^\s*Schedule\s+(I|II|III|IV|V|VI|VII)\s*(?:–|-)\s*([0-9.]+)\s*%/i,
           line
         ) do
      [_, name, rate] -> %{name: String.upcase(name), rate: rate}
      _ -> nil
    end
  end

  defp stop_notification_explanation?(line, %{schedule: "VII", next_serial: 7}),
    do: Regex.match?(~r/^\s*Explanation[.\-—]/, line)

  defp stop_notification_explanation?(_line, _state), do: false

  defp skip_line?(line) do
    trimmed = String.trim(line)

    trimmed == "" or String.starts_with?(trimmed, "S. No.") or
      String.starts_with?(trimmed, "Chapter/Heading/") or
      Regex.match?(~r/^\(1\)\s+\(2\)\s+\(3\)$/, trimmed)
  end

  defp parse_schedule_line(line, state) do
    case Regex.run(~r/^\s*(\d+)\.\s+(.*)$/, line) do
      [_, serial, rest] ->
        serial = String.to_integer(serial)

        if serial == state.next_serial do
          state
          |> finalize_current()
          |> start_rule(serial, rest)
        else
          append_continuation(state, line)
        end

      _ ->
        append_continuation(state, line)
    end
  end

  defp start_rule(state, serial, rest) do
    case Regex.split(~r/\s{3,}/, String.trim(rest), parts: 2) do
      [code, description] ->
        %{
          state
          | current: %{serial: serial, code: code, description: description},
            next_serial: serial + 1
        }

      [description] ->
        %{
          state
          | current: %{serial: serial, code: nil, description: description},
            next_serial: serial + 1
        }
    end
  end

  defp append_continuation(%{current: nil} = state, _line), do: state

  defp append_continuation(state, line) do
    parts = Regex.split(~r/\s{3,}/, String.trim(line), parts: 2)

    current =
      case parts do
        [code, description] ->
          if code_fragment?(code) do
            state.current |> append_code(code) |> append_description(description)
          else
            append_description(state.current, Enum.join(parts, " "))
          end

        [part] ->
          if code_fragment?(part) do
            append_code(state.current, part)
          else
            append_description(state.current, part)
          end
      end

    %{state | current: current}
  end

  defp code_fragment?(value) do
    words = Regex.scan(~r/[A-Za-z]+/, value) |> List.flatten() |> Enum.map(&String.downcase/1)
    allowed = ~w(chapter any other than except or to and from heading sub tariff item)
    Enum.all?(words, &(&1 in allowed)) and (Regex.match?(~r/\d/, value) or words != [])
  end

  defp append_code(current, value), do: Map.update(current, :code, value, &join(&1, value))
  defp append_description(current, ""), do: current

  defp append_description(current, value),
    do: Map.update!(current, :description, &join(&1, value))

  defp join(nil, right), do: String.trim(right)
  defp join(left, right), do: String.trim(left <> " " <> right)

  defp finalize_current(%{current: nil} = state), do: state

  defp finalize_current(state) do
    current = state.current

    if is_binary(current.code) and String.trim(current.code) != "" do
      scope = parse_scope(current.code)

      rule = %{
        serial_number: current.serial,
        schedule: state.schedule,
        total_rate: state.rate,
        raw_code_expression: collapse(current.code),
        raw_description: collapse(current.description),
        parsed_scope: scope,
        parser_confidence: confidence(scope, current.code, current.description)
      }

      %{state | current: nil, rules: [rule | state.rules]}
    else
      %{state | error: {:missing_code_expression, state.schedule, current.serial}}
    end
  end

  defp parse_scope(expression) do
    normalized = String.replace(expression, "–", "-")

    {include_part, exclude_part} =
      case Regex.split(~r/\b(?:except|other than)\b/i, normalized, parts: 2) do
        [include_part, exclude_part] -> {include_part, exclude_part}
        [include_part] -> {include_part, ""}
      end

    %{
      "includes" => codes(include_part),
      "excludes" => codes(exclude_part),
      "ranges" => ranges(include_part),
      "any_chapter" => Regex.match?(~r/\bany\s+(?:other\s+)?chapter\b/i, include_part)
    }
  end

  defp codes(value) do
    ~r/\d(?:[\d ]*\d)?/
    |> Regex.scan(value)
    |> List.flatten()
    |> Enum.map(&String.replace(&1, " ", ""))
    |> Enum.filter(&(String.length(&1) in [2, 4, 6, 8]))
    |> Enum.uniq()
  end

  defp ranges(value) do
    Regex.scan(~r/(\d(?:[\d ]*\d)?)\s+(?:to|-)\s+(\d(?:[\d ]*\d)?)/i, value,
      capture: :all_but_first
    )
    |> Enum.map(fn [first, last] ->
      [String.replace(first, " ", ""), String.replace(last, " ", "")]
    end)
    |> Enum.filter(fn [first, last] -> String.length(first) == String.length(last) end)
  end

  defp confidence(scope, expression, description) do
    simple_scope? =
      length(scope["includes"]) == 1 and scope["ranges"] == [] and
        not scope["any_chapter"] and not Regex.match?(~r/\bor\b/i, expression)

    if simple_scope? and not Regex.match?(@condition_pattern, description),
      do: "automatic",
      else: "review"
  end

  defp collapse(value), do: value |> String.split() |> Enum.join(" ")

  defp validate_counts(rules) do
    actual = Enum.frequencies_by(rules, & &1.schedule)
    if actual == @expected_counts, do: :ok, else: {:error, {:unexpected_schedule_counts, actual}}
  end
end
