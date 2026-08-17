defmodule Mix.Tasks.Nila.StyleGuardTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Nila.StyleGuard

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
end
