defmodule Nila.Assistant.Tools do
  @moduledoc """
  Tools exposed to the assistant, in a provider-neutral shape.

  The tool set is currently empty: the earlier `search_documents` tool queried
  the retired generic `Documents` context and was removed with it. The harness
  (`Nila.Assistant`) — the tool-use loop, streaming, and trace narration — is
  kept fully intact; wire real GST tools (search dumps, open a client-month,
  flag an exception) into the registry when the assistant surface is built on
  the current product.

  Handlers are sourced from application config
  (`config :nila, :assistant_tools, %{name => {spec, fun}}`) so the set is
  extensible without editing this module. `spec` is the provider-neutral tool
  spec; `fun` is a `(scope, input) -> {:ok, map()} | {:error, String.t()}`.

  Org scoping stays enforced here in the dispatch closure via
  `scope.current_org.id` — the model never sees or passes `org_id`. Tool names
  are looked up by exact key, never `String.to_atom/1` on model input.
  """

  alias Nila.Accounts.Scope

  @doc """
  Tool specs in a provider-neutral shape (`name`, `description`, `input_schema`).
  Empty until real GST-facing tools are registered in config.
  """
  def specs do
    for {_name, {spec, _fun}} <- registry(), do: spec
  end

  @doc """
  Dispatch a tool call. Unknown names return `{:error, "unknown tool"}`. Org
  scoping is read from `scope.current_org.id`; the model never passes it.
  """
  def dispatch(%Scope{current_org: nil}, _tool_name, _input), do: {:error, "no current org"}

  def dispatch(%Scope{} = scope, tool_name, input)
      when is_binary(tool_name) and is_map(input) do
    case Map.fetch(registry(), tool_name) do
      {:ok, {_spec, fun}} -> fun.(scope, input)
      :error -> {:error, "unknown tool"}
    end
  end

  defp registry do
    Application.get_env(:nila, :assistant_tools, %{})
  end
end
