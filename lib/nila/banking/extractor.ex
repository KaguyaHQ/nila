defmodule Nila.Banking.Extractor do
  @moduledoc false

  @callback extract(binary(), keyword()) :: {:ok, map()} | {:error, term()}
end
