defmodule Nila.Repo do
  use Ecto.Repo,
    otp_app: :nila,
    adapter: Ecto.Adapters.Postgres

  def fetch(queryable, id) do
    case get(queryable, id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def fetch_one(query) do
    case one(query) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  def fetch_by(queryable, clauses) do
    case get_by(queryable, clauses) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end
end
