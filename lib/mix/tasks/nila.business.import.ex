defmodule Mix.Tasks.Nila.Business.Import do
  @shortdoc "Validates or applies a Nila Business migration packet"

  @moduledoc """
  Validates an agent-prepared JSON packet, then optionally imports its customers,
  addresses, saved items and quotations.

      mix nila.business.import --client-id 123 --actor-id 456 --packet packet.json --dry-run
      mix nila.business.import --client-id 123 --actor-id 456 --packet packet.json --apply

  Dry-run is the default. `--apply` is required before the command writes business data.
  """

  use Mix.Task

  alias Nila.Business.Migration
  alias Nila.Clients.Client
  alias Nila.Repo

  @requirements ["app.start"]
  @switches [
    client_id: :integer,
    actor_id: :integer,
    packet: :string,
    dry_run: :boolean,
    apply: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, positional} = OptionParser.parse!(argv, strict: @switches)
    validate_options!(opts, positional)

    client =
      Repo.get(Client, opts[:client_id]) ||
        Mix.raise("Business client #{opts[:client_id]} does not exist")

    packet = read_packet!(opts[:packet])

    if opts[:apply] do
      case Migration.apply_packet(client, opts[:actor_id], packet) do
        {:ok, report} -> Mix.shell().info(Jason.encode!(report, pretty: true))
        {:error, reason} -> Mix.raise("Business import failed: #{inspect(reason, pretty: true)}")
      end
    else
      case Migration.preview(client, packet) do
        {:ok, report} ->
          Mix.shell().info(Jason.encode!(report, pretty: true))

          if not report.ready? do
            Mix.raise(
              "Packet is not ready. Resolve every error and unresolved field before --apply."
            )
          end

        {:error, reason} ->
          Mix.raise("Could not validate packet: #{inspect(reason)}")
      end
    end
  end

  defp validate_options!(opts, positional) do
    missing = Enum.reject([:client_id, :actor_id, :packet], &opts[&1])

    cond do
      positional != [] ->
        Mix.raise("Unexpected arguments: #{Enum.join(positional, " ")}")

      missing != [] ->
        Mix.raise("Missing required options: #{Enum.map_join(missing, ", ", &"--#{dash(&1)}")}")

      opts[:apply] == true and opts[:dry_run] == true ->
        Mix.raise("Choose either --dry-run or --apply")

      true ->
        :ok
    end
  end

  defp read_packet!(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, packet} when is_map(packet) <- Jason.decode(bytes) do
      packet
    else
      {:error, %Jason.DecodeError{} = error} ->
        Mix.raise("Packet is not valid JSON: #{Exception.message(error)}")

      {:error, reason} ->
        Mix.raise("Could not read packet: #{inspect(reason)}")

      _ ->
        Mix.raise("Packet must contain one JSON object")
    end
  end

  defp dash(value), do: value |> to_string() |> String.replace("_", "-")
end
