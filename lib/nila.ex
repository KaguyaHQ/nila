defmodule Nila do
  @moduledoc """
  Nila keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
end

defmodule Nila.Schema do
  @moduledoc """
  Shared schema defaults for persisted Nila data.
  """

  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset

      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
