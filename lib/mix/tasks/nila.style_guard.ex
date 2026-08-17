defmodule Mix.Tasks.Nila.StyleGuard do
  @shortdoc "Fails when app UI bypasses the Nila design-system tokens"

  @moduledoc """
  Guards the Nila design system in `lib/nila_web`.

  Checks run:

    * **Legacy classes** — hardcoded Tailwind (`bg-slate`, `bg-white`, …) instead
      of moonlight semantic tokens. Zero tolerance, everywhere.

    * **daisyUI components** — raw `btn-*`, `select-*`, `tooltip`, and related
      component recipes are forbidden. DaisyUI supplies theme plumbing only.

    * **Type scale** — raw Tailwind sizes (`text-sm`, `text-xs`, `text-4xl`, …),
      arbitrary `text-[…]`, `tracking-[…]`, and `leading-[…]`, plus the retired
      `text-table` / `text-small` / `text-fine` / `text-micro` steps. The role scale in
      `docs/design/FRONTEND.md#typography` bundles size + line-height + tracking, so
      markup names a role (`text-ui`, `text-context`), never a pixel. Raw sizes
      have been eliminated; the empty allowlist keeps them from returning.

    * **Context type** — 12px is restricted to the `context_text` primitive.
      Secondary-looking operational information remains 14px `text-ui`.

    * **Spacing scale** — arbitrary and off-scale product spacing, plus raw
      numeric structural stacks. Components keep a small primitive scale for
      geometry; composition names `related`, `block`, `section`, or `region`.

    * **Ruling** — ordinary product borders and dividers use the `base-300`
      hairline instead of `base-200` or raw `base-content/NN` mixtures.

    * **Motion** — product transitions use the named fast/calm durations and
      standard easing instead of numeric durations or raw easing utilities.

    * **CSS variables** — every custom property referenced by `app.css` must be
      defined in that source. A utility class name does not imply a runtime token.

  Run with `mix nila.style_guard` (also wired into `mix precommit`).
  """

  use Mix.Task

  @legacy_patterns [
    "bg-slate",
    "text-slate",
    "border-slate",
    "bg-white",
    "rounded-md",
    "shadow-sm"
  ]
  @daisy_component_classes MapSet.new(
                             ~w(btn badge card input textarea select file-input checkbox radio toggle range join alert loading progress radial-progress tooltip drawer dropdown modal swap collapse indicator table tabs tab menu)
                           )
  @daisy_modifier_pattern ~r/\A(?:btn|badge|card|input|textarea|select|file-input|checkbox|radio|toggle|range|join|alert|loading|progress|radial-progress|tooltip|drawer|dropdown|modal|swap|collapse|indicator|table|tabs|tab|menu)-[a-z][\w-]*\z/
  @daisy_modifier_exceptions MapSet.new(
                               ~w(select-none select-text select-all select-auto table-auto table-fixed table-caption table-cell table-column table-column-group table-footer-group table-header-group table-row table-row-group)
                             )
  @class_attribute_start_pattern ~r/\bclass\s*=\s*/
  @class_string_pattern ~r/"([^"]*)"/s
  @data_tip_pattern ~r/\bdata-tip(?=\s*=)/

  # Raw text sizes, plus arbitrary text/tracking/leading. `text-base` is matched
  # only as a size — never the `text-base-content` / `text-base-100` color tokens
  # (the `-` after `base` is a word boundary, so a naive `\btext-base\b` would
  # flag every color use). `leading-none` / `tabular-nums` on figures stay legal;
  # only the arbitrary `leading-[…]` form is caught.
  @type_scale_pattern ~r/\btext-(xs|sm|lg|xl|[2-9]xl)\b|\btext-base(?![-\w])|\btext-\[|\btracking-\[|\bleading-\[|\btext-(table|small|fine|micro)\b/

  # Escape hatch for files allowed to keep raw text sizes. The design-token sweep
  # drove this to empty: every `lib/nila_web` screen now names a role from
  # docs/design/FRONTEND.md#typography. Keep it empty. DO NOT add a file here to silence a
  # new violation — convert it to the role scale instead. The only legitimate
  # entry would be a genuinely print-specific stylesheet measured in pt, which
  # lives in CSS, not markup.
  @type_scale_allowlist MapSet.new([])

  @context_type_pattern ~r/\btext-context\b/
  @context_type_implementation "lib/nila_web/components/typography.ex"

  @component_recipe_owners %{
    "nila-badge" => "lib/nila_web/components/badge.ex",
    "nila-button" => "lib/nila_web/components/button.ex",
    "nila-segmented" => "lib/nila_web/components/button.ex",
    "nila-card" => "lib/nila_web/components/card.ex",
    "nila-field" => "lib/nila_web/components/input.ex",
    "nila-input" => "lib/nila_web/components/input.ex",
    "nila-select" => "lib/nila_web/components/input.ex",
    "nila-textarea" => "lib/nila_web/components/input.ex",
    "nila-checkbox" => "lib/nila_web/components/input.ex",
    "nila-table" => "lib/nila_web/components/table.ex",
    "nila-fold" => "lib/nila_web/components/fold.ex",
    "nila-modal" => "lib/nila_web/components/modal.ex",
    "nila-menu" => "lib/nila_web/components/layouts.ex",
    "nila-callout" => "lib/nila_web/components/feedback.ex",
    "nila-spinner" => "lib/nila_web/components/feedback.ex",
    "nila-progress" => "lib/nila_web/components/feedback.ex",
    "nila-alert" => "lib/nila_web/components/flash.ex",
    "nila-toast" => "lib/nila_web/components/flash.ex"
  }
  @component_recipe_pattern ~r/\bnila-(?:badge|button|segmented|card|field|input|select|textarea|checkbox|table|fold|modal|menu|callout|spinner|progress|alert|toast)(?:-[\w-]+)?\b/

  @spacing_pattern ~r/(?<![\w-])-?(?:p[xysetrbl]?|m[xysetrbl]?|gap(?:-[xy])?|space-[xy])-(\[[^\]]+\]|\d+(?:\.\d+)?)/
  @raw_structural_spacing_pattern ~r/(?<![\w-])space-y-(?:2|4|6|8)\b/
  @spacing_values MapSet.new(~w(0 0.5 1 1.5 2 3 4 6 8 12))
  @spacing_token_allowlist %{
    "lib/nila_web/components/layouts.ex" => MapSet.new(~w(pl-16 pl-64))
  }

  @ruling_pattern ~r/\b(?:border|divide)-base-content\/\d+\b|\b(?:border|divide)-base-200\b/
  @motion_pattern ~r/\bduration-(?:\d+\b|\[[^\]]+\])|\bease-(?:in-out|in|out)\b/
  @css_path "assets/css/app.css"
  @css_variable_definition_pattern ~r/(?:^|[;{])\s*(--[a-zA-Z0-9_-]+)\s*:/m
  @css_variable_reference_pattern ~r/var\(\s*(--[a-zA-Z0-9_-]+)/
  @global_css_block_pattern ~r/(?:@plugin[^\{]*|@theme(?:\s+\w+)?\s*|:root(?:\s*,\s*\.landing)?\s*)\{([^{}]*)\}/s
  @global_css_variable_pattern ~r/^--(?:color|font|text|spacing|radius|shadow|transition|ease|default|nila-(?:ink|accent|info|success|warning|error))-/

  # Product-only checks reuse the live/component scope and deliberately exclude
  # public marketing controller templates. Type scale covers the whole web tree.
  @legacy_globs [
    "lib/nila_web/live/**/*.heex",
    "lib/nila_web/live/**/*.ex",
    "lib/nila_web/components/**/*.ex"
  ]
  @type_scale_globs ["lib/nila_web/**/*.heex", "lib/nila_web/**/*.ex"]
  @spacing_globs @legacy_globs
  @ruling_globs @legacy_globs
  @motion_globs @legacy_globs

  @impl Mix.Task
  def run(_args) do
    legacy = @legacy_globs |> expand() |> Enum.flat_map(&legacy_violations/1)
    daisy_components = @legacy_globs |> expand() |> Enum.flat_map(&daisy_component_violations/1)
    type_scale = @type_scale_globs |> expand() |> Enum.flat_map(&type_scale_violations/1)
    context_type = @type_scale_globs |> expand() |> Enum.flat_map(&context_type_violations/1)

    component_recipes =
      @type_scale_globs |> expand() |> Enum.flat_map(&component_recipe_violations/1)

    spacing = @spacing_globs |> expand() |> Enum.flat_map(&spacing_violations/1)
    ruling = @ruling_globs |> expand() |> Enum.flat_map(&ruling_violations/1)
    motion = @motion_globs |> expand() |> Enum.flat_map(&motion_violations/1)
    css_variables = css_variable_violations(@css_path)

    report(legacy, "legacy hardcoded classes")
    report(daisy_components, "raw daisyUI component classes — use the shared Nila component")
    report(type_scale, "raw type sizes — name a role from docs/design/FRONTEND.md#typography")

    report(
      context_type,
      "12px is context only; secondary operational information remains 14px."
    )

    report(
      component_recipes,
      "closed component recipe used outside its owner — call the shared component"
    )

    report(spacing, "off-scale spacing — use the closed primitives and structural roles")
    report(ruling, "off-system ruling — use the base-300 hairline")
    report(motion, "off-system motion — use the named fast/calm transition vocabulary")
    report(css_variables, "undefined CSS variables — define the token before consuming it")

    if legacy != [] or daisy_components != [] or type_scale != [] or context_type != [] or
         component_recipes != [] or spacing != [] or ruling != [] or motion != [] or
         css_variables != [] do
      Mix.raise("Replace the flagged classes with Nila design-system tokens.")
    end
  end

  defp expand(globs) do
    globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq() |> Enum.sort()
  end

  defp legacy_violations(path) do
    scan(path, fn line -> Enum.filter(@legacy_patterns, &String.contains?(line, &1)) end)
  end

  @doc false
  def daisy_component_violations(path) do
    source = path |> File.read!() |> strip_heex_comments()

    class_violations =
      @class_attribute_start_pattern
      |> Regex.scan(source, return: :index)
      |> Enum.flat_map(fn [{attribute_start, attribute_length}] ->
        value_start = attribute_start + attribute_length

        source
        |> binary_part(value_start, byte_size(source) - value_start)
        |> class_attribute_source()
        |> case do
          nil ->
            []

          attribute_source ->
            @class_string_pattern
            |> Regex.scan(attribute_source, return: :index)
            |> Enum.reject(fn [{quoted_start, _quoted_length}, _string] ->
              comparison_operand?(attribute_source, quoted_start)
            end)
            |> Enum.flat_map(fn [_full, {string_start, string_length}] ->
              attribute_source
              |> binary_part(string_start, string_length)
              |> String.split()
              |> Enum.filter(&daisy_component_class?/1)
              |> Enum.map(fn token ->
                {path, line_number(source, value_start + string_start), token}
              end)
            end)
        end
      end)

    data_tip_violations = pattern_violations(path, @data_tip_pattern)

    Enum.uniq(class_violations ++ data_tip_violations)
  end

  defp class_attribute_source(<<"\"", _rest::binary>> = source) do
    case Regex.run(~r/\A"[^"]*"/s, source) do
      [attribute_source] -> attribute_source
      nil -> nil
    end
  end

  defp class_attribute_source(<<"{", _rest::binary>> = source), do: balanced_braces(source)
  defp class_attribute_source(_source), do: nil

  defp balanced_braces(source), do: balanced_braces(source, source, 0, nil, false, 0)

  defp balanced_braces(_source, <<>>, _depth, _quote, _escaped, _length), do: nil

  defp balanced_braces(source, <<char, rest::binary>>, depth, quote, escaped, length) do
    next_length = length + 1

    cond do
      escaped ->
        balanced_braces(source, rest, depth, quote, false, next_length)

      quote && char == ?\\ ->
        balanced_braces(source, rest, depth, quote, true, next_length)

      quote && char == quote ->
        balanced_braces(source, rest, depth, nil, false, next_length)

      quote ->
        balanced_braces(source, rest, depth, quote, false, next_length)

      char in [?\", ?'] ->
        balanced_braces(source, rest, depth, char, false, next_length)

      char == ?{ ->
        balanced_braces(source, rest, depth + 1, nil, false, next_length)

      char == ?} && depth == 1 ->
        binary_part(source, 0, next_length)

      char == ?} ->
        balanced_braces(source, rest, depth - 1, nil, false, next_length)

      true ->
        balanced_braces(source, rest, depth, nil, false, next_length)
    end
  end

  defp comparison_operand?(source, string_start) do
    source
    |> binary_part(0, string_start)
    |> String.trim_trailing()
    |> then(&(String.ends_with?(&1, "==") or String.ends_with?(&1, "!=")))
  end

  defp daisy_component_class?(token) do
    MapSet.member?(@daisy_component_classes, token) or
      (Regex.match?(@daisy_modifier_pattern, token) and
         !MapSet.member?(@daisy_modifier_exceptions, token))
  end

  defp line_number(source, byte_offset) do
    source
    |> binary_part(0, byte_offset)
    |> String.split("\n")
    |> length()
  end

  defp strip_heex_comments(source) do
    Regex.replace(~r/<%!--.*?--%>/s, source, &preserve_newlines/1)
  end

  defp type_scale_violations(path) do
    if MapSet.member?(@type_scale_allowlist, path) do
      []
    else
      scan(path, fn line -> @type_scale_pattern |> Regex.scan(line) |> Enum.map(&hd/1) end)
    end
  end

  @doc false
  def context_type_violations(@context_type_implementation), do: []

  def context_type_violations(path), do: pattern_violations(path, @context_type_pattern)

  @doc false
  def component_recipe_violations(path) do
    scan(path, fn line ->
      @component_recipe_pattern
      |> Regex.scan(line)
      |> Enum.map(&hd/1)
      |> Enum.reject(&component_recipe_owner?(&1, path))
    end)
  end

  defp recipe_root(token) do
    Enum.find(Map.keys(@component_recipe_owners), &String.starts_with?(token, &1))
  end

  defp component_recipe_owner?(token, path) do
    root = recipe_root(token)

    Map.fetch!(@component_recipe_owners, root) == path or
      (root in ~w(nila-field nila-input nila-select nila-textarea nila-checkbox) and
         path == "lib/nila_web/components/form.ex")
  end

  defp spacing_violations(path) do
    scan(path, fn line ->
      off_scale =
        @spacing_pattern
        |> Regex.scan(line)
        |> Enum.flat_map(fn [token, value] ->
          if MapSet.member?(@spacing_values, value) or spacing_allowlisted?(path, token) do
            []
          else
            [token]
          end
        end)

      raw_structural =
        @raw_structural_spacing_pattern
        |> Regex.scan(line)
        |> Enum.map(&hd/1)

      Enum.uniq(off_scale ++ raw_structural)
    end)
  end

  defp spacing_allowlisted?(path, token) do
    path
    |> then(&Map.get(@spacing_token_allowlist, &1, MapSet.new()))
    |> MapSet.member?(token)
  end

  defp ruling_violations(path), do: pattern_violations(path, @ruling_pattern)
  defp motion_violations(path), do: pattern_violations(path, @motion_pattern)

  @doc false
  def css_variable_violations(path) do
    source = path |> File.read!() |> strip_css_comments() |> strip_css_strings()
    definitions = css_variable_definitions(source)

    global_definitions =
      @global_css_block_pattern
      |> Regex.scan(source)
      |> Enum.flat_map(fn [_match, body] -> css_variable_definitions(body) end)
      |> MapSet.new()

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      @css_variable_reference_pattern
      |> Regex.scan(line)
      |> Enum.map(fn [_match, name] -> name end)
      |> Enum.reject(&css_variable_defined?(&1, definitions, global_definitions))
      |> Enum.uniq()
      |> Enum.map(&{path, line_number, &1})
    end)
  end

  defp css_variable_definitions(source) do
    @css_variable_definition_pattern
    |> Regex.scan(source)
    |> Enum.map(fn [_match, name] -> name end)
    |> MapSet.new()
  end

  defp css_variable_defined?(name, definitions, global_definitions) do
    if Regex.match?(@global_css_variable_pattern, name) do
      MapSet.member?(global_definitions, name)
    else
      MapSet.member?(definitions, name)
    end
  end

  defp strip_css_comments(source) do
    Regex.replace(~r{/\*.*?\*/}s, source, &preserve_newlines/1)
  end

  defp strip_css_strings(source) do
    Regex.replace(~r/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/s, source, &preserve_newlines/1)
  end

  defp preserve_newlines(value), do: String.replace(value, ~r/[^\n]/, " ")

  defp pattern_violations(path, pattern) do
    scan(path, fn line -> pattern |> Regex.scan(line) |> Enum.map(&hd/1) end)
  end

  defp scan(path, finder) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      line |> finder.() |> Enum.map(&{path, line_number, &1})
    end)
  end

  defp report([], _label), do: :ok

  defp report(violations, label) do
    Mix.shell().error("Nila style guard — #{label}:\n")

    Enum.each(violations, fn {path, line_number, token} ->
      Mix.shell().error("  #{path}:#{line_number} #{token}")
    end)

    Mix.shell().error("")
  end
end
