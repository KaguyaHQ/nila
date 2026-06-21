defmodule Mix.Tasks.Nila.StyleGuard do
  @shortdoc "Fails when app UI bypasses the Nila design-system tokens"

  @moduledoc """
  Guards the Nila design system in `lib/nila_web`.

  Two checks run:

    * **Legacy classes** — hardcoded Tailwind (`bg-slate`, `bg-white`, …) instead
      of moonlight semantic tokens. Zero tolerance, everywhere.

    * **Type scale** — raw Tailwind sizes (`text-sm`, `text-xs`, `text-4xl`, …),
      arbitrary `text-[…]`, `tracking-[…]`, and `leading-[…]`. The role scale in
      `docs/design/typography.md` bundles size + line-height + tracking, so markup
      names a role (`text-small`, `text-eyebrow`), never a pixel. Files still
      carrying legacy raw sizes are listed in `@type_scale_allowlist`; that ledger
      shrinks to zero as the design-token sweep lands. A file not on the list that
      introduces a raw size fails the build, so adoption can't regress.

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
  @type_scale_pattern ~r/\btext-(xs|sm|lg|xl|[2-9]xl)\b|\btext-base(?![-\w])|\btext-\[|\btracking-\[|\bleading-\[/

  # Escape hatch for files allowed to keep raw text sizes. The design-token sweep
  # drove this to empty: every `lib/nila_web` screen now names a role from
  # docs/design/typography.md. Keep it empty. DO NOT add a file here to silence a
  # new violation — convert it to the role scale instead. The only legitimate
  # entry would be a genuinely print-specific stylesheet measured in pt, which
  # lives in CSS, not markup.
  @type_scale_allowlist MapSet.new([])

  # Legacy-class check keeps its original scope (live views + components). The
  # type-scale check covers the whole web tree, including controller templates.
  @legacy_globs [
    "lib/nila_web/live/**/*.heex",
    "lib/nila_web/live/**/*.ex",
    "lib/nila_web/components/**/*.ex"
  ]
  @type_scale_globs ["lib/nila_web/**/*.heex", "lib/nila_web/**/*.ex"]

  @impl Mix.Task
  def run(_args) do
    legacy = @legacy_globs |> expand() |> Enum.flat_map(&legacy_violations/1)
    type_scale = @type_scale_globs |> expand() |> Enum.flat_map(&type_scale_violations/1)

    report(legacy, "legacy hardcoded classes")
    report(type_scale, "raw type sizes — name a role from docs/design/typography.md")

    if legacy != [] or type_scale != [] do
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
