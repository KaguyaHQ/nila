defmodule Mix.Tasks.Nila.Whatsapp.Connect do
  @shortdoc "Connects a WhatsApp Cloud API phone number to a firm"

  @moduledoc """
  Connects a Meta WhatsApp Cloud API phone-number ID to a Nila firm.
  Export the access token separately so it is not written into the command:

      export WHATSAPP_ACCESS_TOKEN="..."
      mix nila.whatsapp.connect --org-id 42 --phone-number-id 123456789 --label "Firm WhatsApp"

  Production releases do not include Mix. Run the same operation with:

      bin/nila eval 'IO.inspect(Nila.Release.provision_whatsapp(%{org_id: 42, phone_number_id: "123456789", label: "Firm WhatsApp"}))'
  """

  use Mix.Task

  alias Nila.Integrations

  @requirements ["app.start"]
  @switches [org_id: :integer, phone_number_id: :string, label: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: @switches)
    validate_options!(opts, positional)

    attrs = %{
      org_id: opts[:org_id],
      phone_number_id: opts[:phone_number_id],
      access_token: System.get_env("WHATSAPP_ACCESS_TOKEN"),
      label: opts[:label]
    }

    case Integrations.provision_whatsapp(attrs) do
      {:ok, connection} ->
        Mix.shell().info(
          "Connected WhatsApp phone-number ID #{connection.external_account_id} " <>
            "to organisation #{connection.org_id}."
        )

      {:error, :not_found} ->
        Mix.raise("Organisation #{opts[:org_id]} does not exist.")

      {:error, :whatsapp_account_already_connected} ->
        Mix.raise("That WhatsApp phone-number ID is already connected to another organisation.")

      {:error, :invalid_whatsapp_connection} ->
        Mix.raise("WHATSAPP_ACCESS_TOKEN must be set to a non-empty access token.")

      {:error, %Ecto.Changeset{} = changeset} ->
        Mix.raise("Could not connect WhatsApp: #{inspect(changeset.errors)}")
    end
  end

  defp validate_options!(opts, positional) do
    missing = Enum.reject([:org_id, :phone_number_id], &present?(opts[&1]))

    cond do
      positional != [] ->
        Mix.raise("Unexpected arguments: #{Enum.join(positional, " ")}")

      missing != [] ->
        Mix.raise("Missing required options: #{Enum.map_join(missing, ", ", &option_name/1)}")

      true ->
        :ok
    end
  end

  defp present?(value) when is_integer(value), do: value > 0
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp option_name(key), do: "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))
end
