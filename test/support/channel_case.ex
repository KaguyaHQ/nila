defmodule NilaWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint NilaWeb.Endpoint

      import Phoenix.ChannelTest
      import Nila.AccountsFixtures
    end
  end

  setup tags do
    Nila.DataCase.setup_sandbox(tags)
    :ok
  end
end
