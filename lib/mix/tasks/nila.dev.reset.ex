defmodule Mix.Tasks.Nila.Dev.Reset do
  use Mix.Task
  @shortdoc "Rebuild the local development database and its two workspace logins"
  @moduledoc "Run `mix nila.dev.reset` with the local server stopped. Deletes all data in nila_dev. Refuses other environments and databases."

  def run(_) do
    Mix.Task.run("app.config")
    config = Application.fetch_env!(:nila, Nila.Repo)

    unless Mix.env() == :dev and config[:database] == "nila_dev" and
             config[:hostname] in ["localhost", "127.0.0.1"] and is_nil(config[:url]) do
      Mix.raise("This command only resets the local nila_dev database in MIX_ENV=dev")
    end

    Mix.Task.run("ecto.drop", ["--force"])
    Mix.Task.run("ecto.create")
    Mix.Task.run("ecto.migrate")
    Mix.Task.run("run", ["priv/repo/seeds.exs"])

    Mix.shell().info(
      "Local data rebuilt. Open /users/log_in for Firm workspace and Business workspace."
    )
  end
end
