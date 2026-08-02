defmodule Mix.Tasks.Nila.StyleGuard do
  @shortdoc "Fails when app UI bypasses the Nila design-system tokens"

  @moduledoc """
  Guards the Nila design system in `lib/nila_web`.

  Checks run:

    * **Legacy classes** — hardcoded Tailwind (`bg-slate`, `bg-white`, …) instead
      of moonlight semantic tokens. Zero tolerance, everywhere.

    * **Type scale** — raw Tailwind sizes (`text-sm`, `text-xs`, `text-4xl`, …),
      arbitrary `text-[…]`, `tracking-[…]`, and `leading-[…]`, plus the retired
      `text-table` / `text-small` / `text-fine` / `text-micro` steps. The role scale in
      `docs/design/DESIGN.md#typography` bundles size + line-height + tracking, so
      markup names a role (`text-ui`, `text-meta`), never a pixel. Raw sizes
      have been eliminated; the empty allowlist keeps them from returning.

    * **Spacing scale** — arbitrary and off-scale product spacing, plus raw
      numeric structural stacks. Components keep a small primitive scale for
      geometry; composition names `related`, `block`, `section`, or `region`.

    * **Ruling** — ordinary product borders and dividers use the `base-300`
      hairline instead of `base-200` or raw `base-content/NN` mixtures.

    * **Motion** — product transitions use the named fast/calm durations and
      standard easing instead of numeric durations or raw easing utilities.

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

  # Raw text sizes, plus arbitrary text/tracking/leading. `text-base` is matched
  # only as a size — never the `text-base-content` / `text-base-100` color tokens
  # (the `-` after `base` is a word boundary, so a naive `\btext-base\b` would
  # flag every color use). `leading-none` / `tabular-nums` on figures stay legal;
  # only the arbitrary `leading-[…]` form is caught.
  @type_scale_pattern ~r/\btext-(xs|sm|lg|xl|[2-9]xl)\b|\btext-base(?![-\w])|\btext-\[|\btracking-\[|\bleading-\[|\btext-(table|small|fine|micro)\b/

  # Escape hatch for files allowed to keep raw text sizes. The design-token sweep
  # drove this to empty: every `lib/nila_web` screen now names a role from
  # docs/design/DESIGN.md#typography. Keep it empty. DO NOT add a file here to silence a
  # new violation — convert it to the role scale instead. The only legitimate
  # entry would be a genuinely print-specific stylesheet measured in pt, which
  # lives in CSS, not markup.
  @type_scale_allowlist MapSet.new([])

  @spacing_pattern ~r/(?<![\w-])-?(?:p[xysetrbl]?|m[xysetrbl]?|gap(?:-[xy])?|space-[xy])-(\[[^\]]+\]|\d+(?:\.\d+)?)/
  @raw_structural_spacing_pattern ~r/(?<![\w-])space-y-(?:2|4|6|8)\b/
  @spacing_values MapSet.new(~w(0 0.5 1 1.5 2 3 4 6 8 12))
  @spacing_token_allowlist %{
    "lib/nila_web/components/layouts.ex" => MapSet.new(~w(pl-16 pl-64))
  }

  @ruling_pattern ~r/\b(?:border|divide)-base-content\/\d+\b|\b(?:border|divide)-base-200\b/
  @motion_pattern ~r/\bduration-(?:\d+\b|\[[^\]]+\])|\bease-(?:in-out|in|out)\b/

  # Product-only checks reuse the live/component scope and deliberately exclude
  # the ledger marketing controller templates. Type scale covers the whole web tree.
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
    type_scale = @type_scale_globs |> expand() |> Enum.flat_map(&type_scale_violations/1)
    spacing = @spacing_globs |> expand() |> Enum.flat_map(&spacing_violations/1)
    ruling = @ruling_globs |> expand() |> Enum.flat_map(&ruling_violations/1)
    motion = @motion_globs |> expand() |> Enum.flat_map(&motion_violations/1)

    report(legacy, "legacy hardcoded classes")
    report(type_scale, "raw type sizes — name a role from docs/design/DESIGN.md#typography")
    report(spacing, "off-scale spacing — use the closed primitives and structural roles")
    report(ruling, "off-system ruling — use the base-300 hairline")
    report(motion, "off-system motion — use the named fast/calm transition vocabulary")

    if legacy != [] or type_scale != [] or spacing != [] or ruling != [] or motion != [] do
      Mix.raise("Replace the flagged classes with Nila design-system tokens.")
    end
  end

  defp expand(globs) do
    globs |> Enum.flat_map(&Path.wildcard/1) |> Enum.uniq() |> Enum.sort()
  end

  defp legacy_violations(path) do
    scan(path, fn line -> Enum.filter(@legacy_patterns, &String.contains?(line, &1)) end)
  end

  defp type_scale_violations(path) do
    if MapSet.member?(@type_scale_allowlist, path) do
      []
    else
      scan(path, fn line -> @type_scale_pattern |> Regex.scan(line) |> Enum.map(&hd/1) end)
    end
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
