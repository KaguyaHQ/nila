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

    * **Ruling** — ordinary product borders and dividers use the semantic `rule`
      hairline instead of compatibility tokens or raw mixtures.

    * **Motion** — product transitions use the named fast/calm durations and
      standard easing instead of numeric durations or raw easing utilities.

    * **CSS variables** — every custom property referenced by `app.css` must be
      defined in that source. A utility class name does not imply a runtime token.

    * **Foreground scale** — Nila's global semantic ink aliases the pinned Radix
      Slate scale exactly once, without formula-generated or component-local copies.

    * **Surface authority** — Radix Slate aliases, light semantic surfaces, and
      daisyUI compatibility names map exactly once to the pinned Radix contract.
      The upstream substrate and registered authored-color recipes are pinned by
      content digest so their pigments cannot drift behind valid aliases.

    * **Authored pigment** — raw OKLCH and neutral `color-mix()` are confined to
      exact Radix recipes or the documented brand-composition sections.

    * **Interactive color** — Radix `accent` and `focus` aliases map exactly once
      through the blue scale. Product markup selects component meaning instead of
      raw primary text, borders, focus rings, or arbitrary primary opacity.

    * **Status color** — semantic info, success, warning, and error aliases map
      exactly once to pinned Radix Sky, Green, Amber, and Red. Retired generated
      `--nila-{status}-*` copies cannot return.

  Run with `mix nila.style_guard` (also wired into `mix precommit`).
  """

  use Mix.Task

  @legacy_patterns [
    "bg-slate",
    "text-slate",
    "border-slate",
    "bg-white",
    "bg-base-100",
    "bg-base-200",
    "bg-base-300",
    "text-base-100",
    "border-base-300",
    "divide-base-300",
    "ring-base-300",
    "moonlight-soft",
    "rounded-md",
    "shadow-sm"
  ]
  @raw_palette_families ~w(white black slate gray zinc neutral stone red orange amber yellow lime green emerald teal cyan sky blue indigo violet purple fuchsia pink rose)
  @color_utility_prefix "(?:bg|text|placeholder|border(?:-[xytrblse])?|divide|ring(?:-offset)?|inset-ring|outline|shadow|drop-shadow|inset-shadow|text-shadow|fill|stroke|from|via|to|caret|accent|decoration)"
  @opacity_suffix "(?:/(?:\\[[^]]+\\]|\\(--[^)]+\\)|[0-9.]+))?"
  @raw_palette_utility_pattern Regex.compile!(
                                 "\\b" <>
                                   @color_utility_prefix <>
                                   "-(?:" <>
                                   Enum.join(@raw_palette_families, "|") <>
                                   ")(?:-\\d{1,3})?" <>
                                   @opacity_suffix <>
                                   "(?![\\w-])"
                               )
  @daisy_plumbing_utility_pattern Regex.compile!(
                                    "\\b" <>
                                      @color_utility_prefix <>
                                      "-(?:base-(?:100|200|300|content)|neutral(?:-content)?|secondary(?:-content)?)" <>
                                      @opacity_suffix <>
                                      "(?![\\w-])"
                                  )
  @semantic_scale_utility_pattern Regex.compile!(
                                    "\\b" <>
                                      @color_utility_prefix <>
                                      "-(?:accent|focus|info|success|warning|error)-(?:a?(?:1[0-2]|[1-9])|contrast|surface|indicator|track)" <>
                                      @opacity_suffix <>
                                      "(?![\\w-])"
                                  )
  @arbitrary_pigment_utility_pattern Regex.compile!(
                                       "\\b" <> @color_utility_prefix <> "-\\[[^]]+\\]"
                                     )
  @direct_color_scale_variable_pattern ~r/var\(\s*--(?:gray|slate|blue|accent|focus|info|success|warning|error|sky|green|amber|red|black|white)-(?:a?(?:1[0-2]|[1-9])|contrast|surface|indicator|track)\s*\)/
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
    "nila-link" => "lib/nila_web/components/button.ex",
    "nila-segmented" => "lib/nila_web/components/button.ex",
    "nila-card" => "lib/nila_web/components/card.ex",
    "nila-field" => "lib/nila_web/components/input.ex",
    "nila-file-drop" => "lib/nila_web/components/form.ex",
    "nila-file-accent" => "lib/nila_web/components/form.ex",
    "nila-file-remove" => "lib/nila_web/components/form.ex",
    "nila-file-error" => "lib/nila_web/components/form.ex",
    "nila-input" => "lib/nila_web/components/input.ex",
    "nila-select" => "lib/nila_web/components/input.ex",
    "nila-textarea" => "lib/nila_web/components/input.ex",
    "nila-checkbox" => "lib/nila_web/components/input.ex",
    "nila-table" => "lib/nila_web/components/table.ex",
    "nila-fold" => "lib/nila_web/components/fold.ex",
    "nila-modal" => "lib/nila_web/components/modal.ex",
    "nila-menu" => "lib/nila_web/components/layouts.ex",
    "nila-action-menu" => "lib/nila_web/components/menu.ex",
    "nila-picker" => "lib/nila_web/components/selectable_list.ex",
    "nila-callout" => "lib/nila_web/components/feedback.ex",
    "nila-spinner" => "lib/nila_web/components/feedback.ex",
    "nila-progress" => "lib/nila_web/components/feedback.ex",
    "nila-evidence-trigger" => "lib/nila_web/components/evidence.ex",
    "nila-settings-link" => "lib/nila_web/components/layouts.ex",
    "nila-account-trigger" => "lib/nila_web/components/layouts.ex",
    "nila-sales-review-item" => "lib/nila_web/components/gst/review/sales_live.ex",
    "nila-status-swatch" => "lib/nila_web/live/dev/design_system_live.ex",
    "nila-arrival-sort-error" => "lib/nila_web/components/today/arrivals.ex",
    "nila-whatsapp-status" => "lib/nila_web/live/settings/connectors_live.ex",
    "nila-whatsapp-config-warning" => "lib/nila_web/live/settings/connectors_live.ex",
    "nila-connector-error" => "lib/nila_web/live/settings/connectors_live.ex",
    "nila-upload-identification" => "lib/nila_web/live/gst/upload_live.ex",
    "nila-upload-error" => "lib/nila_web/live/gst/upload_live.ex",
    "nila-upload-job-label" => "lib/nila_web/live/gst/upload_live.ex",
    "nila-upload-retry" => "lib/nila_web/live/gst/upload_live.ex",
    "nila-verdict-alarm" => "lib/nila_web/components/gst/month/verdict.ex",
    "nila-deadline-error" => "lib/nila_web/components/gst/month/verdict.ex",
    "nila-deadline-warning" => "lib/nila_web/components/gst/month/verdict.ex",
    "nila-exception-outcome" => "lib/nila_web/components/gst/exceptions/surface.ex",
    "nila-exception-mismatch" => "lib/nila_web/components/gst/exceptions/surface.ex",
    "nila-itc-awaiting-document" => "lib/nila_web/components/gst/exceptions/itc.ex",
    "nila-itc-value-blocked" => "lib/nila_web/components/gst/exceptions/itc.ex",
    "nila-itc-status-blocked" => "lib/nila_web/components/gst/exceptions/itc.ex",
    "nila-evidence-issue-chip" => "lib/nila_web/components/gst/month/evidence.ex",
    "nila-evidence-issue-index" => "lib/nila_web/components/gst/month/evidence.ex",
    "nila-gstr1-mismatch" => "lib/nila_web/components/gst/month/evidence.ex",
    "nila-month-precondition" => "lib/nila_web/components/gst/month/precondition.ex",
    "nila-purchase-itc-negative" => "lib/nila_web/components/gst/month/purchase.ex",
    "nila-purchase-open-row" => "lib/nila_web/components/gst/month/purchase.ex",
    "nila-gstr1-blocked-next-move" => "lib/nila_web/components/gst/month/sales.ex",
    "nila-gstr1-required-item" => "lib/nila_web/components/gst/month/sales.ex",
    "nila-gstr1-required-link" => "lib/nila_web/components/gst/month/sales.ex",
    "nila-workings-accepted" => "lib/nila_web/components/gst/month/workings.ex",
    "nila-gstr3b-provisional" => "lib/nila_web/components/gst/month/filing.ex",
    "nila-gstr1-handoff" => "lib/nila_web/components/gst/month/filing.ex",
    "nila-sales-register-row" => "lib/nila_web/components/gst/month/sales.ex",
    "nila-workpaper-tab" => "lib/nila_web/components/gst/month/workpaper.ex",
    "nila-workings-reference" => "lib/nila_web/components/gst/month/workings.ex",
    "nila-alert" => "lib/nila_web/components/flash.ex",
    "nila-alert-copy" => "lib/nila_web/components/flash.ex",
    "nila-flash-group" => "lib/nila_web/components/layouts.ex",
    "nila-toast" => "lib/nila_web/components/flash.ex"
  }
  @component_recipe_pattern Regex.compile!(
                              "\\b(?:" <>
                                (@component_recipe_owners
                                 |> Map.keys()
                                 |> Enum.sort_by(&String.length/1, :desc)
                                 |> Enum.map_join("|", &Regex.escape/1)) <>
                                ")(?:-[\\w-]+)?\\b"
                            )

  @spacing_pattern ~r/(?<![\w-])-?(?:p[xysetrbl]?|m[xysetrbl]?|gap(?:-[xy])?|space-[xy])-(\[[^\]]+\]|\d+(?:\.\d+)?)/
  @raw_structural_spacing_pattern ~r/(?<![\w-])space-y-(?:2|4|6|8)\b/
  @spacing_values MapSet.new(~w(0 0.5 1 1.5 2 3 4 6 8 12))
  @spacing_token_allowlist %{
    "lib/nila_web/components/layouts.ex" => MapSet.new(~w(pl-16 pl-64))
  }

  @ruling_pattern ~r/\b(?:border|divide)-base-content\/\d+\b|\b(?:border|divide)-base-200\b/
  @motion_pattern ~r/\bduration-(?:\d+\b|\[[^\]]+\])|\bease-(?:in-out|in|out)\b/
  @interactive_color_pattern ~r/(?<![\w-])(?:[\w\[\].&-]+:)*(?:(?:text|border|ring)-primary(?!-)(?:\/(?:\[[^\]]+\]|[\d.]+))?|[\w-]+-primary\/(?:\[[^\]]+\]|[\d.]+))/
  @css_path "assets/css/app.css"
  @css_variable_definition_pattern ~r/(?:^|[;{])\s*(--[a-zA-Z0-9_-]+)\s*:/m
  @css_variable_reference_pattern ~r/var\(\s*(--[a-zA-Z0-9_-]+)/
  @global_css_block_pattern ~r/(?:@plugin[^\{]*|@theme(?:\s+\w+)?\s*|:root(?:\s*,\s*\.landing)?\s*)\{([^{}]*)\}/s
  @global_css_variable_pattern ~r/^--(?:color|font|text|spacing|radius|shadow|transition|ease|default|(?:accent|focus|info|success|warning|error)|nila-(?:ink|accent))-/
  @ink_semantic_targets Map.new(
                          [
                            {"--color-base-content", "--gray-12"},
                            {"--nila-ink-12", "--gray-12"}
                          ] ++
                            for(
                              step <- 1..12,
                              do: {"--nila-ink-a#{step}", "--gray-a#{step}"}
                            )
                        )
  @ink_semantic_declaration_pattern ~r/(--(?:color-base-content|nila-ink-(?:12|a(?:1[0-2]|[1-9]))))\s*:\s*([^;]+);/
  @accent_semantic_targets Map.new(
                             for(step <- 1..12, do: {"--accent-#{step}", "--blue-#{step}"}) ++
                               for(
                                 step <- 1..12,
                                 do: {"--accent-a#{step}", "--blue-a#{step}"}
                               ) ++
                               [
                                 {"--accent-contrast", "--blue-contrast"},
                                 {"--accent-surface", "--blue-surface"},
                                 {"--accent-indicator", "--blue-indicator"},
                                 {"--accent-track", "--blue-track"}
                               ] ++
                               for(
                                 step <- 1..12,
                                 do: {"--focus-#{step}", "--accent-#{step}"}
                               ) ++
                               for(
                                 step <- 1..12,
                                 do: {"--focus-a#{step}", "--accent-a#{step}"}
                               )
                           )
  @accent_semantic_declaration_pattern ~r/(--(?:accent-(?:a?(?:1[0-2]|[1-9])|contrast|surface|indicator|track)|focus-a?(?:1[0-2]|[1-9])))\s*:\s*([^;]+);/
  @status_families %{
    "info" => "sky",
    "success" => "green",
    "warning" => "amber",
    "error" => "red"
  }
  @surface_semantic_targets Map.new(
                              for(step <- 1..12, do: {"--gray-#{step}", "var(--slate-#{step})"}) ++
                                for(
                                  step <- 1..12,
                                  do: {"--gray-a#{step}", "var(--slate-a#{step})"}
                                ) ++
                                [
                                  {"--gray-contrast", "var(--slate-contrast)"},
                                  {"--gray-surface", "var(--slate-surface)"},
                                  {"--gray-indicator", "var(--slate-indicator)"},
                                  {"--gray-track", "var(--slate-track)"},
                                  {"--color-background", "white"},
                                  {"--color-overlay", "var(--black-a6)"},
                                  {"--color-panel-solid", "white"},
                                  {"--color-panel-translucent", "rgba(255, 255, 255, 0.7)"},
                                  {"--color-panel", "var(--color-panel-solid)"},
                                  {"--color-surface", "rgba(255, 255, 255, 0.85)"},
                                  {"--color-base-100", "var(--color-panel-solid)"},
                                  {"--color-base-200", "var(--gray-2)"},
                                  {"--color-base-300", "var(--gray-a5)"},
                                  {"--color-secondary", "var(--gray-9)"},
                                  {"--color-secondary-content", "var(--gray-contrast)"},
                                  {"--color-accent", "var(--accent-9)"},
                                  {"--color-accent-content", "var(--accent-contrast)"},
                                  {"--color-neutral", "var(--gray-12)"},
                                  {"--color-neutral-content", "var(--gray-contrast)"},
                                  {"--color-canvas", "var(--color-background)"},
                                  {"--color-panel-surface", "var(--color-panel-solid)"},
                                  {"--color-panel-translucent-surface",
                                   "var(--color-panel-translucent)"},
                                  {"--color-control-surface", "var(--color-surface)"},
                                  {"--color-quiet", "var(--gray-a2)"},
                                  {"--color-interactive", "var(--gray-a3)"},
                                  {"--color-rule", "var(--gray-a5)"},
                                  {"--color-inverse", "var(--gray-contrast)"},
                                  {"--color-inverse-surface", "var(--gray-12)"},
                                  {"--color-muted-indicator", "var(--gray-indicator)"},
                                  {"--color-focus", "var(--focus-8)"},
                                  {"--color-scrim", "var(--black-a8)"},
                                  {"--shadow-moon", "var(--shadow-5)"},
                                  {"--shadow-moon-lg", "var(--shadow-6)"}
                                ]
                            )
  @surface_semantic_declaration_pattern ~r/(--(?:gray-(?:a?(?:1[0-2]|[1-9])|contrast|surface|indicator|track)|color-(?:background|overlay|panel(?:-solid|-translucent|-surface|-translucent-surface)?|surface|base-(?:100|200|300)|secondary(?:-content)?|accent(?:-content)?|neutral(?:-content)?|canvas|control-surface|quiet|interactive|rule|inverse(?:-surface)?|muted-indicator|focus|scrim)|shadow-moon(?:-lg)?))\s*:\s*([^;]+);/
  @css_named_colors ~w(aliceblue antiquewhite aqua aquamarine azure beige bisque black blanchedalmond blue blueviolet brown burlywood cadetblue chartreuse chocolate coral cornflowerblue cornsilk crimson cyan darkblue darkcyan darkgoldenrod darkgray darkgreen darkgrey darkkhaki darkmagenta darkolivegreen darkorange darkorchid darkred darksalmon darkseagreen darkslateblue darkslategray darkslategrey darkturquoise darkviolet deeppink deepskyblue dimgray dimgrey dodgerblue firebrick floralwhite forestgreen fuchsia gainsboro ghostwhite gold goldenrod gray green greenyellow grey honeydew hotpink indianred indigo ivory khaki lavender lavenderblush lawngreen lemonchiffon lightblue lightcoral lightcyan lightgoldenrodyellow lightgray lightgreen lightgrey lightpink lightsalmon lightseagreen lightskyblue lightslategray lightslategrey lightsteelblue lightyellow lime limegreen linen magenta maroon mediumaquamarine mediumblue mediumorchid mediumpurple mediumseagreen mediumslateblue mediumspringgreen mediumturquoise mediumvioletred midnightblue mintcream mistyrose moccasin navajowhite navy oldlace olive olivedrab orange orangered orchid palegoldenrod palegreen paleturquoise palevioletred papayawhip peachpuff peru pink plum powderblue purple rebeccapurple red rosybrown royalblue saddlebrown salmon sandybrown seagreen seashell sienna silver skyblue slateblue slategray slategrey snow springgreen steelblue tan teal thistle tomato turquoise violet wheat white whitesmoke yellow yellowgreen)
  @raw_css_pigment_pattern Regex.compile!(
                             "#[0-9a-fA-F]{3,8}(?![\\w-])|(?<![\\w-])(?:rgba?|hsla?|hwb|device-cmyk|oklch|oklab|lab|lch|color)\\(|(?<![\\w-])(?:" <>
                               Enum.join(@css_named_colors, "|") <> ")(?![\\w-])"
                           )
  @allowed_color_mix_fragments [
    "@supports (color: color-mix(in oklab, white, black))",
    "@supports (box-shadow: 0 0 0 1px color-mix(in oklab, white, black))",
    "color-mix(in oklab, var(--gray-a3), var(--gray-3) 25%)",
    "color-mix(in oklab, var(--gray-a5), var(--gray-6))",
    "color-mix(in oklab, var(--gray-12) 4.5%, transparent)"
  ]
  @pinned_color_contracts [
    {"radix-themes-3.3-substrate", "/* Radix Themes 3.3 Slate light scale",
     "/* Radix Themes 3.3 semantic status",
     "d33a0da7bd26d0a06a586c0ed1aa4987d604ec586118fceaf784c99fd80bed55"},
    {"radix-themes-3.3-status-scales", "/* Radix Themes 3.3 semantic status",
     "/* Nila sea-blue candidate",
     "dcdb5dcb83dcf78a7cae1badd83bff67ff1b5cdf658839e6bb8db7b8688a9856"},
    {"validated-nila-blue", "/* Nila sea-blue candidate",
     "/* Radix Themes semantic color aliases.",
     "65610732d7d0c75897575ca5d0d0ae06f4c83a9941410bf82c6f88e1af8e9be2"},
    {"brand-atmosphere", "/* Moonlight ground:",
     "/* Compatibility names for the pinned Radix elevation scale.",
     "1c03c571e780beecf3edd9beb5a93c6c7b35edce5bf7c28dba015257aaa765e6"},
    {"landing-artwork", "/* ── Moonlight marketing homepage", "/* Correction ripple:",
     "ab9be7541db5813c7eb742a5f224da40d25e8df06c3f7cf3510399bd2c1ffe46"}
  ]
  @status_semantic_targets Map.new(
                             Enum.flat_map(@status_families, fn {status, family} ->
                               for(
                                 step <- 1..12,
                                 do: {"--#{status}-#{step}", "--#{family}-#{step}"}
                               ) ++
                                 for(
                                   step <- 1..12,
                                   do: {"--#{status}-a#{step}", "--#{family}-a#{step}"}
                                 ) ++
                                 for(
                                   role <- ~w(contrast surface indicator track),
                                   do: {"--#{status}-#{role}", "--#{family}-#{role}"}
                                 ) ++
                                 [
                                   {"--color-#{status}", "--#{status}-9"},
                                   {"--color-#{status}-content", "--#{status}-contrast"}
                                 ]
                             end)
                           )
  @status_semantic_declaration_pattern ~r/(--(?:(?:info|success|warning|error)-(?:a?(?:1[0-2]|[1-9])|contrast|surface|indicator|track)|color-(?:info|success|warning|error)(?:-content)?))\s*:\s*([^;]+);/
  @retired_status_pattern ~r/--nila-(?:info|success|warning|error)-[a-zA-Z0-9_-]+/

  # Product-only checks reuse the live/component scope and deliberately exclude
  # public marketing controller templates. Type scale covers the whole web tree.
  @legacy_globs [
    "lib/nila_web/live/**/*.heex",
    "lib/nila_web/live/**/*.ex",
    "lib/nila_web/components/**/*.ex"
  ]
  @type_scale_globs ["lib/nila_web/**/*.heex", "lib/nila_web/**/*.ex"]
  @raw_palette_globs @type_scale_globs
  @spacing_globs @legacy_globs
  @ruling_globs @legacy_globs
  @motion_globs @legacy_globs
  @interactive_color_globs @type_scale_globs

  @impl Mix.Task
  def run(_args) do
    legacy = @legacy_globs |> expand() |> Enum.flat_map(&legacy_violations/1)
    raw_palette = @raw_palette_globs |> expand() |> Enum.flat_map(&raw_palette_violations/1)

    daisy_plumbing =
      @raw_palette_globs |> expand() |> Enum.flat_map(&daisy_plumbing_violations/1)

    semantic_scale =
      @raw_palette_globs |> expand() |> Enum.flat_map(&semantic_scale_violations/1)

    arbitrary_pigment =
      @raw_palette_globs |> expand() |> Enum.flat_map(&arbitrary_pigment_violations/1)

    direct_color_scale =
      @raw_palette_globs |> expand() |> Enum.flat_map(&direct_color_scale_violations/1)

    daisy_components = @legacy_globs |> expand() |> Enum.flat_map(&daisy_component_violations/1)
    type_scale = @type_scale_globs |> expand() |> Enum.flat_map(&type_scale_violations/1)
    context_type = @type_scale_globs |> expand() |> Enum.flat_map(&context_type_violations/1)

    component_recipes =
      @type_scale_globs |> expand() |> Enum.flat_map(&component_recipe_violations/1)

    spacing = @spacing_globs |> expand() |> Enum.flat_map(&spacing_violations/1)
    ruling = @ruling_globs |> expand() |> Enum.flat_map(&ruling_violations/1)
    motion = @motion_globs |> expand() |> Enum.flat_map(&motion_violations/1)

    interactive_color =
      @interactive_color_globs |> expand() |> Enum.flat_map(&interactive_color_violations/1)

    css_variables = css_variable_violations(@css_path)
    ink_scale = ink_scale_violations(@css_path)
    surface_scale = surface_scale_violations(@css_path)
    pinned_color_contract = pinned_color_contract_violations(@css_path)
    neutral_mix = neutral_mix_violations(@css_path)
    authored_color = authored_color_violations(@css_path)
    accent_scale = accent_scale_violations(@css_path)
    status_scale = status_scale_violations(@css_path)

    report(legacy, "legacy hardcoded classes")
    report(raw_palette, "raw palette utility — use a semantic product color role")
    report(daisy_plumbing, "daisyUI plumbing color — use a semantic product color role")
    report(semantic_scale, "raw semantic scale step — use the unstepped semantic role")
    report(arbitrary_pigment, "arbitrary pigment utility — use a semantic product color role")
    report(direct_color_scale, "direct color-scale variable — use a semantic product role")
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
    report(ruling, "off-system ruling — use the semantic rule hairline")
    report(motion, "off-system motion — use the named fast/calm transition vocabulary")

    report(
      interactive_color,
      "raw primary role — choose a component meaning instead of pigment or opacity"
    )

    report(css_variables, "undefined CSS variables — define the token before consuming it")

    report(
      ink_scale,
      "off-system foreground scale — alias each global ink token to pinned Radix Slate once"
    )

    report(
      surface_scale,
      "off-system surfaces — preserve the pinned Radix Slate and semantic surface contract"
    )

    report(
      pinned_color_contract,
      "pinned color contract drift — update from the named upstream/owned source deliberately"
    )

    report(
      neutral_mix,
      "unauthorized neutral color-mix — use an exact Radix recipe or semantic token"
    )

    report(
      authored_color,
      "unregistered authored pigment — scope it to a documented brand composition"
    )

    report(
      accent_scale,
      "off-system interactive scale — alias Radix accent and focus roles exactly once"
    )

    report(
      status_scale,
      "off-system status scale — alias pinned Radix status roles once; remove retired copies"
    )

    if legacy != [] or raw_palette != [] or daisy_plumbing != [] or semantic_scale != [] or
         arbitrary_pigment != [] or direct_color_scale != [] or daisy_components != [] or
         type_scale != [] or
         component_recipes != [] or spacing != [] or ruling != [] or motion != [] or
         interactive_color != [] or css_variables != [] or ink_scale != [] or accent_scale != [] or
         surface_scale != [] or pinned_color_contract != [] or neutral_mix != [] or
         authored_color != [] or status_scale != [] do
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
  def raw_palette_violations(path) do
    color_class_violations(path, @raw_palette_utility_pattern)
  end

  @doc false
  def daisy_plumbing_violations(path) do
    path
    |> color_class_violations(@daisy_plumbing_utility_pattern)
    |> Enum.reject(&match?({_path, _line, "text-base-content"}, &1))
  end

  @doc false
  def semantic_scale_violations(path) do
    color_class_violations(path, @semantic_scale_utility_pattern)
  end

  @doc false
  def arbitrary_pigment_violations(path) do
    color_class_violations(path, @arbitrary_pigment_utility_pattern)
  end

  @doc false
  def direct_color_scale_violations(path) do
    pattern_violations(path, @direct_color_scale_variable_pattern)
  end

  defp color_class_violations(path, pattern) do
    direct = pattern_violations(path, pattern)

    parsed =
      class_token_violations(path, fn token ->
        pattern |> Regex.scan(token) |> Enum.map(&hd/1)
      end)

    Enum.uniq(direct ++ parsed)
  end

  @doc false
  def daisy_component_violations(path) do
    class_violations =
      class_token_violations(path, fn token ->
        if daisy_component_class?(token), do: [token], else: []
      end)

    data_tip_violations = pattern_violations(path, @data_tip_pattern)

    Enum.uniq(class_violations ++ data_tip_violations)
  end

  defp class_token_violations(path, finder) do
    source = path |> File.read!() |> strip_heex_comments()

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
            line = line_number(source, value_start + string_start)

            attribute_source
            |> binary_part(string_start, string_length)
            |> String.split()
            |> Enum.flat_map(finder)
            |> Enum.map(&{path, line, &1})
          end)
      end
    end)
    |> Enum.uniq()
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
    @component_recipe_owners
    |> Map.keys()
    |> Enum.sort_by(&String.length/1, :desc)
    |> Enum.find(&String.starts_with?(token, &1))
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
  def interactive_color_violations(path), do: pattern_violations(path, @interactive_color_pattern)

  @doc false
  def ink_scale_violations(path) do
    source = path |> File.read!() |> strip_css_comments() |> strip_css_strings()

    declarations =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_number} ->
        @ink_semantic_declaration_pattern
        |> Regex.scan(line)
        |> Enum.map(fn [_match, name, value] -> {name, String.trim(value), line_number} end)
      end)

    invalid_mappings =
      Enum.flat_map(declarations, fn {name, value, line_number} ->
        expected = "var(#{Map.fetch!(@ink_semantic_targets, name)})"

        if value == expected, do: [], else: [{path, line_number, name}]
      end)

    declarations_by_name = Enum.group_by(declarations, &elem(&1, 0))

    cardinality_violations =
      Enum.flat_map(@ink_semantic_targets, fn {name, _target} ->
        case Map.get(declarations_by_name, name, []) do
          [] -> [{path, 1, name}]
          [_declaration] -> []
          [_first | duplicates] -> Enum.map(duplicates, &{path, elem(&1, 2), name})
        end
      end)

    Enum.uniq(invalid_mappings ++ cardinality_violations)
  end

  @doc false
  def surface_scale_violations(path) do
    exact_semantic_violations(
      path,
      @surface_semantic_declaration_pattern,
      @surface_semantic_targets
    )
  end

  @doc false
  def pinned_color_contract_violations(path) do
    source = path |> File.read!() |> String.replace("\r\n", "\n")

    Enum.flat_map(@pinned_color_contracts, fn {name, start_marker, end_marker, expected} ->
      case marked_section(source, start_marker, end_marker) do
        {:ok, section} ->
          actual =
            section
            |> String.trim()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)

          if actual == expected, do: [], else: [{path, 1, name}]

        :error ->
          [{path, 1, name}]
      end
    end)
  end

  @doc false
  def neutral_mix_violations(path) do
    scan(path, fn line ->
      if String.contains?(line, "color-mix(") and
           not Enum.any?(@allowed_color_mix_fragments, &String.contains?(line, &1)) do
        ["color-mix("]
      else
        []
      end
    end)
  end

  @doc false
  def authored_color_violations(path) do
    source = File.read!(path)

    stripped =
      Enum.reduce(@pinned_color_contracts, source, fn
        {_name, start_marker, end_marker, _digest}, acc ->
          strip_marked_section(acc, start_marker, end_marker)
      end)

    stripped =
      @allowed_color_mix_fragments
      |> Enum.reduce(stripped, fn fragment, acc ->
        String.replace(acc, fragment, preserve_newlines(fragment))
      end)
      |> strip_css_comments()
      |> strip_css_strings()

    stripped
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      @raw_css_pigment_pattern
      |> Regex.scan(line)
      |> Enum.map(fn [match] -> {path, line_number, match} end)
    end)
  end

  @doc false
  def accent_scale_violations(path) do
    source = path |> File.read!() |> strip_css_comments() |> strip_css_strings()

    declarations =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_number} ->
        @accent_semantic_declaration_pattern
        |> Regex.scan(line)
        |> Enum.map(fn [_match, name, value] -> {name, String.trim(value), line_number} end)
      end)

    invalid_mappings =
      Enum.flat_map(declarations, fn {name, value, line_number} ->
        expected = "var(#{Map.fetch!(@accent_semantic_targets, name)})"

        if value == expected, do: [], else: [{path, line_number, name}]
      end)

    declarations_by_name = Enum.group_by(declarations, &elem(&1, 0))

    cardinality_violations =
      Enum.flat_map(@accent_semantic_targets, fn {name, _target} ->
        case Map.get(declarations_by_name, name, []) do
          [] -> [{path, 1, name}]
          [_declaration] -> []
          [_first | duplicates] -> Enum.map(duplicates, &{path, elem(&1, 2), name})
        end
      end)

    Enum.uniq(invalid_mappings ++ cardinality_violations)
  end

  defp exact_semantic_violations(path, declaration_pattern, targets) do
    source = path |> File.read!() |> strip_css_comments() |> strip_css_strings()

    declarations =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_number} ->
        declaration_pattern
        |> Regex.scan(line)
        |> Enum.map(fn [_match, name, value] -> {name, String.trim(value), line_number} end)
      end)

    invalid_mappings =
      Enum.flat_map(declarations, fn {name, value, line_number} ->
        expected = Map.fetch!(targets, name)
        if value == expected, do: [], else: [{path, line_number, name}]
      end)

    declarations_by_name = Enum.group_by(declarations, &elem(&1, 0))

    cardinality_violations =
      Enum.flat_map(targets, fn {name, _target} ->
        case Map.get(declarations_by_name, name, []) do
          [] -> [{path, 1, name}]
          [_declaration] -> []
          [_first | duplicates] -> Enum.map(duplicates, &{path, elem(&1, 2), name})
        end
      end)

    Enum.uniq(invalid_mappings ++ cardinality_violations)
  end

  @doc false
  def status_scale_violations(path) do
    source = path |> File.read!() |> strip_css_comments() |> strip_css_strings()

    declarations =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_number} ->
        @status_semantic_declaration_pattern
        |> Regex.scan(line)
        |> Enum.map(fn [_match, name, value] -> {name, String.trim(value), line_number} end)
      end)

    invalid_mappings =
      Enum.flat_map(declarations, fn {name, value, line_number} ->
        expected = "var(#{Map.fetch!(@status_semantic_targets, name)})"

        if value == expected, do: [], else: [{path, line_number, name}]
      end)

    declarations_by_name = Enum.group_by(declarations, &elem(&1, 0))

    cardinality_violations =
      Enum.flat_map(@status_semantic_targets, fn {name, _target} ->
        case Map.get(declarations_by_name, name, []) do
          [] -> [{path, 1, name}]
          [_declaration] -> []
          [_first | duplicates] -> Enum.map(duplicates, &{path, elem(&1, 2), name})
        end
      end)

    retired = pattern_violations(path, @retired_status_pattern)

    Enum.uniq(invalid_mappings ++ cardinality_violations ++ retired)
  end

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

  defp strip_marked_section(source, start_marker, end_marker) do
    pattern =
      ~r/#{Regex.escape(start_marker)}.*?(?=#{Regex.escape(end_marker)})/s

    Regex.replace(pattern, source, &preserve_newlines/1)
  end

  defp marked_section(source, start_marker, end_marker) do
    with {start, _length} <- :binary.match(source, start_marker),
         {finish, _length} <-
           :binary.match(source, end_marker, scope: {start, byte_size(source) - start}) do
      {:ok, binary_part(source, start, finish - start)}
    else
      :nomatch -> :error
    end
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
