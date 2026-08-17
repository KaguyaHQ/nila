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
end
