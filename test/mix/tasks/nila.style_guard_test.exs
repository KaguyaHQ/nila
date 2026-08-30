defmodule Mix.Tasks.Nila.StyleGuardTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Nila.StyleGuard

  test "rejects raw daisyUI component recipes" do
    path =
      Path.join(System.tmp_dir!(), "nila-daisy-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(
      path,
      ~s(<button class="btn btn-soft tooltip tooltip-left" data-tip="Save">Save</button>\n)
    )

    on_exit(fn -> File.rm(path) end)

    violations = StyleGuard.daisy_component_violations(path)

    assert Enum.sort(violations) ==
             Enum.sort([
               {path, 1, "btn"},
               {path, 1, "btn-soft"},
               {path, 1, "tooltip"},
               {path, 1, "tooltip-left"},
               {path, 1, "data-tip"}
             ])
  end

  test "rejects raw palette utilities across properties and variants" do
    path =
      Path.join(System.tmp_dir!(), "nila-raw-palette-#{System.unique_integer([:positive])}.heex")

    File.write!(
      path,
      """
      <div class="ring-white/(--shell-ring) hover:bg-slate-2 text-red-500 border-t-black/10 fill-blue-9 from-amber-3 inset-ring-rose-500 text-shadow-gray-900"></div>
      """
    )

    on_exit(fn -> File.rm(path) end)

    assert Enum.map(StyleGuard.raw_palette_violations(path), &elem(&1, 2)) == [
             "ring-white/(--shell-ring)",
             "bg-slate-2",
             "text-red-500",
             "border-t-black/10",
             "fill-blue-9",
             "from-amber-3",
             "inset-ring-rose-500",
             "text-shadow-gray-900"
           ]
  end

  test "rejects raw color classes returned by helper functions" do
    path =
      Path.join(System.tmp_dir!(), "nila-helper-color-#{System.unique_integer([:positive])}.ex")

    File.write!(path, ~s(defp state_class, do: "bg-red-500 ring-white/20"\n))
    on_exit(fn -> File.rm(path) end)

    assert Enum.map(StyleGuard.raw_palette_violations(path), &elem(&1, 2)) == [
             "bg-red-500",
             "ring-white/20"
           ]
  end

  test "allows product roles and rejects daisyUI color plumbing" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nila-semantic-color-#{System.unique_integer([:positive])}.heex"
      )

    File.write!(
      path,
      ~s(<div class="bg-inverse-surface text-inverse border-rule bg-muted-indicator text-neutral-content"></div>\n)
    )

    on_exit(fn -> File.rm(path) end)
    assert StyleGuard.raw_palette_violations(path) == []
    assert [{^path, 1, "text-neutral-content"}] = StyleGuard.daisy_plumbing_violations(path)

    File.write!(
      path,
      ~s(<div class="text-base-content bg-base-content border-secondary fill-neutral"></div>\n)
    )

    assert Enum.map(StyleGuard.daisy_plumbing_violations(path), &elem(&1, 2)) == [
             "bg-base-content",
             "border-secondary",
             "fill-neutral"
           ]
  end

  test "rejects semantic scale steps and arbitrary pigment utilities" do
    path =
      Path.join(System.tmp_dir!(), "nila-color-role-#{System.unique_integer([:positive])}.heex")

    File.write!(
      path,
      """
      <div class="outline-focus-8 bg-error-a3 placeholder-red-500 bg-[#fff] text-[rgb(1,2,3)] outline-focus text-error"></div>
      """
    )

    on_exit(fn -> File.rm(path) end)

    assert Enum.map(StyleGuard.semantic_scale_violations(path), &elem(&1, 2)) == [
             "outline-focus-8",
             "bg-error-a3"
           ]

    assert Enum.map(StyleGuard.raw_palette_violations(path), &elem(&1, 2)) == [
             "placeholder-red-500"
           ]

    assert Enum.map(StyleGuard.arbitrary_pigment_violations(path), &elem(&1, 2)) == [
             "bg-[#fff]",
             "text-[rgb(1,2,3)]"
           ]
  end

  test "rejects direct Radix and semantic scale variables in product source" do
    path =
      Path.join(System.tmp_dir!(), "nila-direct-scale-#{System.unique_integer([:positive])}.heex")

    File.write!(
      path,
      """
      <div style="color: var(--gray-3)" class="bg-[var(--accent-a6)]"></div>
      """
    )

    on_exit(fn -> File.rm(path) end)

    assert Enum.map(StyleGuard.direct_color_scale_violations(path), &elem(&1, 2)) == [
             "var(--gray-3)",
             "var(--accent-a6)"
           ]
  end

  test "rejects daisyUI classes in multiline HEEx class expressions" do
    path =
      Path.join(System.tmp_dir!(), "nila-daisy-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(
      path,
      """
      <div
        class={[
          "btn",
          @active && "tooltip-left"
        ]}
      >Content</div>
      """
    )

    on_exit(fn -> File.rm(path) end)

    assert Enum.sort(StyleGuard.daisy_component_violations(path)) ==
             Enum.sort([{path, 3, "btn"}, {path, 4, "tooltip-left"}])
  end

  test "allows colliding Tailwind utilities and shared Nila recipes" do
    path =
      Path.join(System.tmp_dir!(), "nila-daisy-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(
      path,
      ~s(<.button><span class="nila-input-error select-none table-fixed table-cell">Save</span></.button>\n)
    )

    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.daisy_component_violations(path) == []
  end

  test "ignores comparison values inside class expressions" do
    path =
      Path.join(System.tmp_dir!(), "nila-daisy-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(path, ~s(<div class={["nila-modal", @variant == "modal" && "px-4"]}></div>\n))
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.daisy_component_violations(path) == []
  end

  test "allows shared Nila recipes and component calls" do
    path =
      Path.join(System.tmp_dir!(), "nila-daisy-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(path, ~s(<.button><span class="nila-input-error">Save</span></.button>\n))
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.daisy_component_violations(path) == []
  end

  test "rejects raw context typography outside its primitive" do
    path =
      Path.join(System.tmp_dir!(), "nila-style-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(path, "<p>ordinary</p>\n<p class=\"text-context\">Too small</p>\n")
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.context_type_violations(path) == [{path, 2, "text-context"}]
  end

  test "allows the context typography primitive to own the token" do
    assert StyleGuard.context_type_violations("lib/nila_web/components/typography.ex") == []
  end

  test "rejects closed component recipes outside their owner" do
    path =
      Path.join(System.tmp_dir!(), "nila-recipe-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(path, ~s(<span class="nila-badge">Bypassed wrapper</span>\n))
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.component_recipe_violations(path) == [{path, 1, "nila-badge"}]
  end

  test "allows a component to own its recipe" do
    assert StyleGuard.component_recipe_violations("lib/nila_web/components/badge.ex") == []
  end

  test "rejects raw primary text, borders, rings, and opacity" do
    path =
      Path.join(System.tmp_dir!(), "nila-color-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(
      path,
      ~s(<div class="text-primary hover:border-primary ring-primary/20 bg-primary/[0.04]"></div>\n)
    )

    on_exit(fn -> File.rm(path) end)

    assert Enum.map(StyleGuard.interactive_color_violations(path), &elem(&1, 2)) == [
             "text-primary",
             "hover:border-primary",
             "ring-primary/20",
             "bg-primary/[0.04]"
           ]
  end

  test "allows deliberate solid primary surfaces with contrast" do
    path =
      Path.join(System.tmp_dir!(), "nila-color-guard-#{System.unique_integer([:positive])}.heex")

    File.write!(path, ~s(<div class="bg-primary text-primary-content"></div>\n))
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.interactive_color_violations(path) == []
  end

  test "accepts semantic foreground aliases to the pinned Slate scale" do
    path =
      Path.join(System.tmp_dir!(), "nila-ink-scale-#{System.unique_integer([:positive])}.css")

    File.write!(path, valid_ink_css())
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.ink_scale_violations(path) == []
  end

  test "rejects formula-generated semantic foreground tokens" do
    path =
      Path.join(System.tmp_dir!(), "nila-ink-scale-#{System.unique_integer([:positive])}.css")

    source =
      String.replace(
        valid_ink_css(),
        "--color-base-content: var(--gray-12);",
        "--color-base-content: color-mix(in oklab, black 80%, transparent);"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert [{^path, _line, "--color-base-content"}] = StyleGuard.ink_scale_violations(path)
  end

  test "rejects local copies of global semantic foreground tokens" do
    path =
      Path.join(System.tmp_dir!(), "nila-ink-scale-#{System.unique_integer([:positive])}.css")

    File.write!(path, valid_ink_css() <> ".local { --nila-ink-a11: var(--gray-a11); }\n")
    on_exit(fn -> File.rm(path) end)

    assert [{^path, _line, "--nila-ink-a11"}] = StyleGuard.ink_scale_violations(path)
  end

  test "accepts the pinned Radix semantic surface contract" do
    assert StyleGuard.surface_scale_violations("assets/css/app.css") == []
    assert StyleGuard.pinned_color_contract_violations("assets/css/app.css") == []
  end

  test "rejects drift in pinned Radix pigment and registered authored color" do
    path =
      Path.join(System.tmp_dir!(), "nila-pinned-color-#{System.unique_integer([:positive])}.css")

    source =
      "assets/css/app.css"
      |> File.read!()
      |> String.replace("--slate-2: #f9f9fb;", "--slate-2: hotpink;", global: false)
      |> String.replace("--amber-2: #fefbe9;", "--amber-2: hotpink;", global: false)
      |> String.replace(
        "background-color: oklch(98.5% 0.005 235);",
        "background-color: oklch(50% 0.3 20);",
        global: false
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    violations = StyleGuard.pinned_color_contract_violations(path)
    assert {path, 1, "radix-themes-3.3-substrate"} in violations
    assert {path, 1, "radix-themes-3.3-status-scales"} in violations
    assert {path, 1, "brand-atmosphere"} in violations
  end

  test "rejects a semantic surface that drifts from Radix" do
    path =
      Path.join(System.tmp_dir!(), "nila-surface-scale-#{System.unique_integer([:positive])}.css")

    source =
      "assets/css/app.css"
      |> File.read!()
      |> String.replace("--color-background: white;", "--color-background: var(--gray-1);",
        global: false
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert Enum.any?(
             StyleGuard.surface_scale_violations(path),
             &match?({^path, _line, "--color-background"}, &1)
           )
  end

  test "rejects unauthorized mixtures and every raw CSS pigment syntax" do
    path =
      Path.join(
        System.tmp_dir!(),
        "nila-authored-color-#{System.unique_integer([:positive])}.css"
      )

    File.write!(
      path,
      """
      .a { background: color-mix(in oklab, white 80%, black); color: oklch(50% 0.1 240); }
      .b { color: #fff; background: rgb(1 2 3); border-color: color(display-p3 1 0 0); }
      .c { color: white; background: hwb(20 10% 20%); border-color: device-cmyk(0 1 1 0); }
      .d { color: rebeccapurple; background: red; }
      """
    )

    on_exit(fn -> File.rm(path) end)

    assert [{^path, 1, "color-mix("}] = StyleGuard.neutral_mix_violations(path)

    matches = Enum.map(StyleGuard.authored_color_violations(path), &elem(&1, 2))
    assert "oklch(" in matches
    assert "#fff" in matches
    assert "rgb(" in matches
    assert "color(" in matches
    assert "white" in matches
    assert "hwb(" in matches
    assert "device-cmyk(" in matches
    assert "rebeccapurple" in matches
    assert "red" in matches
  end

  test "accepts Radix accent and focus aliases through the blue family" do
    path =
      Path.join(System.tmp_dir!(), "nila-accent-scale-#{System.unique_integer([:positive])}.css")

    File.write!(path, valid_accent_css())
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.accent_scale_violations(path) == []
  end

  test "rejects a focus alias that bypasses accent" do
    path =
      Path.join(System.tmp_dir!(), "nila-accent-scale-#{System.unique_integer([:positive])}.css")

    source =
      String.replace(
        valid_accent_css(),
        "--focus-8: var(--accent-8);",
        "--focus-8: var(--blue-8);"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert [{^path, _line, "--focus-8"}] = StyleGuard.accent_scale_violations(path)
  end

  test "rejects missing or duplicated accent aliases" do
    path =
      Path.join(System.tmp_dir!(), "nila-accent-scale-#{System.unique_integer([:positive])}.css")

    source =
      valid_accent_css()
      |> String.replace("  --accent-a7: var(--blue-a7);\n", "")
      |> Kernel.<>(".local { --accent-a8: var(--blue-a8); }\n")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    violations = StyleGuard.accent_scale_violations(path)
    assert {path, 1, "--accent-a7"} in violations
    assert Enum.any?(violations, &match?({^path, _line, "--accent-a8"}, &1))
  end

  test "accepts semantic status aliases to the pinned Radix families" do
    path =
      Path.join(System.tmp_dir!(), "nila-status-scale-#{System.unique_integer([:positive])}.css")

    File.write!(path, valid_status_css())
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.status_scale_violations(path) == []
  end

  test "rejects wrong, formula-generated, missing, and duplicated status aliases" do
    path =
      Path.join(System.tmp_dir!(), "nila-status-scale-#{System.unique_integer([:positive])}.css")

    source =
      valid_status_css()
      |> String.replace("  --info-11: var(--sky-11);\n", "  --info-11: var(--blue-11);\n")
      |> String.replace(
        "  --success-a3: var(--green-a3);\n",
        "  --success-a3: color-mix(in oklch, var(--color-success) 9%, transparent);\n"
      )
      |> String.replace("  --warning-a6: var(--amber-a6);\n", "")
      |> Kernel.<>(".local { --error-a11: var(--red-a11); }\n")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    violations = StyleGuard.status_scale_violations(path)
    assert Enum.any?(violations, &match?({^path, _line, "--info-11"}, &1))
    assert Enum.any?(violations, &match?({^path, _line, "--success-a3"}, &1))
    assert {path, 1, "--warning-a6"} in violations
    assert Enum.any?(violations, &match?({^path, _line, "--error-a11"}, &1))
  end

  test "rejects retired generated status tokens in definitions and references" do
    path =
      Path.join(System.tmp_dir!(), "nila-status-scale-#{System.unique_integer([:positive])}.css")

    File.write!(
      path,
      valid_status_css() <>
        ".legacy { --nila-warning-a3: yellow; background: var(--nila-error-surface); }\n"
    )

    on_exit(fn -> File.rm(path) end)

    tokens = Enum.map(StyleGuard.status_scale_violations(path), &elem(&1, 2))
    assert "--nila-warning-a3" in tokens
    assert "--nila-error-surface" in tokens
  end

  test "shared status recipes preserve exact Radix roles" do
    css = File.read!("assets/css/app.css")

    readable_ink = %{
      "info" => "--info-a11",
      "success" => "--success-12",
      "warning" => "--warning-12",
      "error" => "--error-a11"
    }

    for status <- ~w(info success warning error) do
      badge = css_rule(css, ".nila-badge[data-variant=\"#{status}\"]")
      assert badge =~ "--nila-badge-bg: var(--#{status}-a3);"
      assert badge =~ "--nila-badge-ink: var(#{Map.fetch!(readable_ink, status)});"

      callout = css_rule(css, ".nila-callout[data-kind=\"#{status}\"]")
      assert callout =~ "--nila-callout-bg: var(--#{status}-a3);"
      assert callout =~ "--nila-callout-border: var(--#{status}-a6);"
      assert callout =~ "--nila-callout-ink: var(#{Map.fetch!(readable_ink, status)});"
    end

    info_alert = css_rule(css, ".nila-alert[data-kind=\"info\"]")
    assert info_alert =~ "--nila-alert-bg: var(--info-surface);"
    assert info_alert =~ "--nila-alert-border: var(--info-a6);"
    assert info_alert =~ "--nila-alert-ink: var(--info-a11);"

    error_alert = css_rule(css, ".nila-alert[data-kind=\"error\"]")
    assert error_alert =~ "--nila-alert-bg: var(--error-surface);"
    assert error_alert =~ "--nila-alert-border: var(--error-a6);"
    assert error_alert =~ "--nila-alert-ink: var(--error-a11);"

    flash_group = css_rule(css, ".nila-flash-group")
    assert flash_group =~ "display: flex;"
    assert flash_group =~ "pointer-events: none;"

    toast = css_rule(css, ".nila-toast")
    assert toast =~ "width: fit-content;"
    assert toast =~ "max-width: 100%;"

    alert = css_rule(css, ".nila-alert")
    assert alert =~ "padding: 0.75rem;"

    error_button = css_rule(css, ".nila-button[data-variant=\"error\"]")
    assert error_button =~ "--nila-button-bg: var(--error-11);"
    assert error_button =~ "--nila-button-hover-bg: var(--error-12);"
    assert error_button =~ "--nila-button-ink: var(--error-contrast);"

    success_button = css_rule(css, ".nila-button[data-variant=\"success\"]")
    assert success_button =~ "--nila-button-bg: var(--success-11);"
    assert success_button =~ "--nila-button-hover-bg: var(--success-12);"
    assert success_button =~ "--nila-button-ink: var(--success-contrast);"
  end

  test "shared interactive recipes preserve exact Radix roles" do
    css = File.read!("assets/css/app.css")

    primary = css_rule(css, ".nila-button[data-variant=\"primary\"]")
    assert primary =~ "--nila-button-bg: var(--accent-9);"
    assert primary =~ "--nila-button-hover-bg: var(--accent-10);"
    assert primary =~ "--nila-button-active-bg: var(--accent-10);"
    assert primary =~ "--nila-button-ink: var(--accent-contrast);"

    soft = css_rule(css, ".nila-button[data-variant=\"soft\"]")
    assert soft =~ "--nila-button-bg: var(--accent-a3);"
    assert soft =~ "--nila-button-hover-bg: var(--accent-a4);"
    assert soft =~ "--nila-button-active-bg: var(--accent-a5);"
    assert soft =~ "--nila-button-ink: var(--accent-a11);"

    outline = css_rule(css, ".nila-button[data-variant=\"outline\"]")
    assert outline =~ "--nila-button-hover-bg: var(--accent-a2);"
    assert outline =~ "--nila-button-active-bg: var(--accent-a3);"
    assert outline =~ "--nila-button-ink: var(--accent-a11);"
    assert outline =~ "box-shadow: inset 0 0 0 1px var(--accent-a8);"

    disabled =
      css_rule(
        css,
        ".nila-button:disabled, .nila-button[aria-disabled=\"true\"]"
      )

    assert disabled =~ "box-shadow: none;"

    persistent_card =
      css_rule(css, ".nila-sales-review-item[data-selected=\"true\"]")

    assert persistent_card =~ "border-color: var(--accent-a8);"
    assert persistent_card =~ "background: var(--color-panel-solid);"
    assert persistent_card =~ "box-shadow: inset 0 0 0 1px var(--accent-a8);"
    refute persistent_card =~ "background: var(--accent-a3);"

    refute css =~ "nila-purchase-scorecard"
    refute css =~ "--nila-accent-"
  end

  test "shared density recipes preserve controlled geometry families" do
    css = File.read!("assets/css/app.css")

    assert css =~ "--nila-control-height-compact: 1.75rem;"
    assert css =~ "--nila-control-height-standard: 2rem;"
    assert css =~ "--nila-control-height-prominent: 2.5rem;"
    assert css =~ "--nila-table-row-height-compact: 2.25rem;"
    assert css =~ "--nila-table-row-height-standard: 2.75rem;"

    compact_button = css_rule(css, ".nila-button[data-size=\"xs\"]")
    assert compact_button =~ "height: var(--nila-control-height-compact);"
    assert compact_button =~ "gap: 0.25rem;"

    compact_icon =
      css_rule(
        css,
        ".nila-button[data-size=\"xs\"] > :where(svg, [class^=\"hero-\"], [class*=\" hero-\"])"
      )

    assert compact_icon =~ "width: var(--nila-control-icon-compact);"
    assert compact_icon =~ "height: var(--nila-control-icon-compact);"

    prominent_button = css_rule(css, ".nila-button[data-size=\"lg\"]")
    assert prominent_button =~ "height: var(--nila-control-height-prominent);"
    assert prominent_button =~ "font-size: var(--text-body);"
    assert prominent_button =~ "line-height: var(--text-body--line-height);"

    prominent_icon =
      css_rule(
        css,
        ".nila-button[data-size=\"lg\"] > :where(svg, [class^=\"hero-\"], [class*=\" hero-\"])"
      )

    assert prominent_icon =~ "width: var(--nila-control-icon-prominent);"
    assert prominent_icon =~ "height: var(--nila-control-icon-prominent);"

    segmented = css_rule(css, ".nila-segmented")
    assert segmented =~ "height: var(--nila-control-height-standard);"

    scan_table = css_rule(css, ".nila-table[data-mode=\"scan\"] :is(th, td)")
    assert scan_table =~ "height: var(--nila-table-row-height-compact);"
    assert scan_table =~ "padding: 0.25rem 0.75rem;"
    assert scan_table =~ "vertical-align: middle;"

    standard_table =
      css_rule(
        css,
        ".nila-table[data-mode=\"worklist\"] :is(th, td),\n.nila-table[data-mode=\"review\"] :is(th, td)"
      )

    assert standard_table =~ "height: var(--nila-table-row-height-standard);"
    assert standard_table =~ "padding: 0.5rem 1rem;"

    worklist_table = css_rule(css, ".nila-table[data-mode=\"worklist\"] :is(th, td)")
    assert worklist_table =~ "vertical-align: middle;"

    review_table = css_rule(css, ".nila-table[data-mode=\"review\"] tbody :is(th, td)")
    assert review_table =~ "vertical-align: top;"
  end

  test "rejects undefined CSS variable references" do
    path =
      Path.join(System.tmp_dir!(), "nila-css-variable-#{System.unique_integer([:positive])}.css")

    File.write!(path, ".broken { color: var(--missing-ink); }\n")
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.css_variable_violations(path) == [{path, 1, "--missing-ink"}]
  end

  test "allows component-local CSS variables declared by a recipe" do
    path =
      Path.join(System.tmp_dir!(), "nila-css-variable-#{System.unique_integer([:positive])}.css")

    File.write!(path, ".recipe { --recipe-ink: black; color: var(--recipe-ink); }\n")
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.css_variable_violations(path) == []
  end

  test "does not accept a CSS variable definition hidden in a comment" do
    path =
      Path.join(System.tmp_dir!(), "nila-css-variable-#{System.unique_integer([:positive])}.css")

    File.write!(path, "/* --missing-ink: black; */\n.consumer { color: var(--missing-ink); }\n")
    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.css_variable_violations(path) == [{path, 2, "--missing-ink"}]
  end

  test "does not accept a global design token declared in a component scope" do
    path =
      Path.join(System.tmp_dir!(), "nila-css-variable-#{System.unique_integer([:positive])}.css")

    File.write!(
      path,
      ".owner { --nila-ink-a11: black; }\n.consumer { color: var(--nila-ink-a11); }\n"
    )

    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.css_variable_violations(path) == [{path, 2, "--nila-ink-a11"}]
  end

  test "does not accept a CSS variable definition hidden in a string" do
    path =
      Path.join(System.tmp_dir!(), "nila-css-variable-#{System.unique_integer([:positive])}.css")

    File.write!(
      path,
      ".fake { content: \"; --missing-ink: black\"; }\n.consumer { color: var(--missing-ink); }\n"
    )

    on_exit(fn -> File.rm(path) end)

    assert StyleGuard.css_variable_violations(path) == [{path, 2, "--missing-ink"}]
  end

  defp css_rule(css, selector) do
    normalized_css = String.replace(css, ~r/\s+/, " ")
    normalized_selector = String.replace(selector, ~r/\s+/, " ")
    [_, body] = Regex.run(~r/#{Regex.escape(normalized_selector)}\s*\{([^}]*)\}/, normalized_css)
    body
  end

  defp valid_ink_css do
    aliases =
      [
        {"--color-base-content", "--gray-12"},
        {"--nila-ink-12", "--gray-12"}
      ] ++ Enum.map(1..12, &{"--nila-ink-a#{&1}", "--gray-a#{&1}"})

    ":root {\n" <>
      Enum.map_join(aliases, "", fn {name, target} -> "  #{name}: var(#{target});\n" end) <>
      "}\n"
  end

  defp valid_status_css do
    families = %{
      "info" => "sky",
      "success" => "green",
      "warning" => "amber",
      "error" => "red"
    }

    aliases =
      Enum.flat_map(families, fn {status, family} ->
        Enum.map(1..12, &{"--#{status}-#{&1}", "--#{family}-#{&1}"}) ++
          Enum.map(1..12, &{"--#{status}-a#{&1}", "--#{family}-a#{&1}"}) ++
          Enum.map(~w(contrast surface indicator track), fn role ->
            {"--#{status}-#{role}", "--#{family}-#{role}"}
          end) ++
          [
            {"--color-#{status}", "--#{status}-9"},
            {"--color-#{status}-content", "--#{status}-contrast"}
          ]
      end)

    ":root {\n" <>
      Enum.map_join(aliases, "", fn {name, target} -> "  #{name}: var(#{target});\n" end) <>
      "}\n"
  end

  defp valid_accent_css do
    aliases =
      Enum.map(1..12, &{"--accent-#{&1}", "--blue-#{&1}"}) ++
        Enum.map(1..12, &{"--accent-a#{&1}", "--blue-a#{&1}"}) ++
        [
          {"--accent-contrast", "--blue-contrast"},
          {"--accent-surface", "--blue-surface"},
          {"--accent-indicator", "--blue-indicator"},
          {"--accent-track", "--blue-track"}
        ] ++
        Enum.map(1..12, &{"--focus-#{&1}", "--accent-#{&1}"}) ++
        Enum.map(1..12, &{"--focus-a#{&1}", "--accent-a#{&1}"})

    ":root {\n" <>
      Enum.map_join(aliases, "", fn {name, target} -> "  #{name}: var(#{target});\n" end) <>
      "}\n"
  end
end
