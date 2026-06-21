defmodule Nila.Storage do
  @moduledoc """
  Storage boundary for uploaded source files and generated artifacts.

  Development and test use local disk. Production can swap the adapter without
  changing document or workflow code.
  """

  @callback put(String.t(), iodata(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback get(String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  @callback delete(String.t(), keyword()) :: :ok | {:error, term()}
  @callback url(String.t(), keyword()) :: String.t()

  def put(key, data, opts \\ []), do: adapter().put(key, data, opts)
  def get(key, opts \\ []), do: adapter().get(key, opts)
  def delete(key, opts \\ []), do: adapter().delete(key, opts)
  def url(key, opts \\ []), do: adapter().url(key, opts)

  defp adapter do
    Application.fetch_env!(:nila, __MODULE__)
    |> Keyword.fetch!(:adapter)
  end
end
