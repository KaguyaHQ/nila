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
        "--color-base-content: var(--slate-12);",
        "--color-base-content: color-mix(in oklab, black 80%, transparent);"
      )

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)

    assert [{^path, _line, "--color-base-content"}] = StyleGuard.ink_scale_violations(path)
  end

  test "rejects local copies of global semantic foreground tokens" do
    path =
      Path.join(System.tmp_dir!(), "nila-ink-scale-#{System.unique_integer([:positive])}.css")

    File.write!(path, valid_ink_css() <> ".local { --nila-ink-a11: var(--slate-a11); }\n")
    on_exit(fn -> File.rm(path) end)

    assert [{^path, _line, "--nila-ink-a11"}] = StyleGuard.ink_scale_violations(path)
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

    persistent_cards =
      css_rule(
        css,
        ".nila-sales-review-item[data-selected=\"true\"], .nila-purchase-scorecard[data-selected=\"true\"]"
      )

    assert persistent_cards =~ "border-color: var(--accent-a8);"
    assert persistent_cards =~ "background: var(--color-base-100);"
    assert persistent_cards =~ "box-shadow: inset 0 0 0 1px var(--accent-a8);"
    refute persistent_cards =~ "background: var(--accent-a3);"

    refute css =~ "--nila-accent-"
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
        {"--color-base-content", "--slate-12"},
        {"--nila-ink-12", "--slate-12"}
      ] ++ Enum.map(1..12, &{"--nila-ink-a#{&1}", "--slate-a#{&1}"})

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
