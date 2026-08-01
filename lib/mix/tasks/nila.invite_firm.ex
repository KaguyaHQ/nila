defmodule Mix.Tasks.Nila.InviteFirm do
  @shortdoc "Creates a firm and invites its first owner"

  @moduledoc """
  Creates a firm and sends its first owner a one-time setup link.

      mix nila.invite_firm --firm "Raman & Associates" --name "Anita Raman" --email "anita@example.com"

  Production runs as a compiled release without Mix. Invoke the same operation
  there with:

      bin/nila eval 'IO.inspect(Nila.Release.invite_firm(%{firm: "Raman & Associates", name: "Anita Raman", email: "anita@example.com"}))'
  """

  use Mix.Task

  alias Nila.Accounts

  @requirements ["app.start"]
  @switches [firm: :string, name: :string, email: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: @switches)
    validate_options!(opts, positional)

    case Accounts.provision_firm(
           %{name: String.trim(opts[:firm])},
           %{name: String.trim(opts[:name]), email: String.trim(opts[:email])},
           &invite_url/1
         ) do
      {:ok, %{org: org, user: user}} ->
        Mix.shell().info("Created #{org.name} and sent an invitation to #{user.email}.")

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("Could not invite firm: #{format_errors(changeset)}")

      {:error, {:email_delivery_failed, details, reason}} ->
        Mix.raise("""
        Created #{details.org.name}, but invitation email delivery failed: #{inspect(reason)}
        Send this one-time setup link manually: #{details.invite_url}
        """)
    end
  end

  defp validate_options!(opts, positional) do
    missing = Enum.reject([:firm, :name, :email], &present?(opts[&1]))

    cond do
      positional != [] ->
        Mix.raise("Unexpected arguments: #{Enum.join(positional, " ")}")

      missing != [] ->
        Mix.raise("Missing required options: #{Enum.map_join(missing, ", ", &"--#{&1}")}")

      true ->
        :ok
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp invite_url(token), do: NilaWeb.Endpoint.url() <> "/users/invite/" <> token

  defp format_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, text ->
        String.replace(text, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  end
end
