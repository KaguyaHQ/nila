defmodule Mix.Tasks.Nila.SeedGstDemo do
  @shortdoc "Backfills the Breeze Oct-2025 demo month into the database"

  @moduledoc """
  Loads the engine-produced Breeze Tech · October 2025 register off disk
  (`tmp/register/breeze-2025-10/`) into real DB state: ensures an org and a
  "Breeze Tech" client exist, copies the scanned bills into `Nila.Storage` under
  tenant-scoped keys, and upserts one `client_month` row (period "2025-10",
  state "worked").

      mix nila.seed_gst_demo            # uses/creates the dev org
      mix nila.seed_gst_demo --org 1   # backfills under an existing org

  Idempotent — safe to re-run.
  """

  use Mix.Task

  import Ecto.Query, only: [from: 2]

  alias Nila.Clients
  alias Nila.Clients.Client
  alias Nila.Gst.Purchase.Months
  alias Nila.Orgs
  alias Nila.Repo
  alias Nila.Storage

  @dir "tmp/register/breeze-2025-10"
  @period "2025-10"
  @client_name "Breeze Tech"

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _} = OptionParser.parse(args, strict: [org: :integer])

    Mix.Task.run("app.start")

    org = resolve_org(opts)
    client = ensure_client(org)

    basenames = copy_images(org.id, client.id)

    {:ok, client_month} =
      Months.upsert(%{
        org_id: org.id,
        client_id: client.id,
        period: @period,
        state: "worked",
        register_rows: read_json("register_rows.json"),
        recon: read_json("recon.json"),
        summary: read_json("summary.json")
      })

    Mix.shell().info(
      "Seeded client_month ##{client_month.id} (#{@client_name} · #{@period}) with " <>
        "#{length(basenames)} evidence images under orgs/#{org.id}/clients/#{client.id}/#{@period}/evidence/."
    )
  end

  defp resolve_org(opts) do
    case Keyword.get(opts, :org) do
      nil -> default_org()
      org_id -> Orgs.get_org!(org_id)
    end
  end

  # Seed into an org a real login can actually reach: the first org that has a
  # member. Minting a fresh orphan org (no membership) leaves the demo month
  # unreachable behind the workspace's org scope. Fall back to a dev org only
  # when the DB has no memberships at all.
  defp default_org do
    case Repo.one(from m in "org_memberships", select: m.org_id, limit: 1) do
      nil ->
        Orgs.create_org!(%{
          name: "Nila Dev CA",
          legal_name: "Nila Dev CA LLP",
          gstin: "33AAAAA0000A1Z5"
        })

      org_id ->
        Orgs.get_org!(org_id)
    end
  end

  defp ensure_client(org) do
    case Repo.get_by(Client, org_id: org.id, name: @client_name) do
      nil ->
        {:ok, client} =
          Clients.create_client(%{org_id: org.id, name: @client_name, type: "company"})

        client

      client ->
        client
    end
  end

  defp copy_images(org_id, client_id) do
    @dir
    |> Path.join("images")
    |> File.ls!()
    |> Enum.sort()
    |> Enum.map(fn basename ->
      bytes = File.read!(Path.join([@dir, "images", basename]))
      key = Months.evidence_key(org_id, client_id, @period, basename)
      {:ok, _} = Storage.put(key, bytes, content_type: content_type(basename))
      basename
    end)
  end

  defp content_type(basename) do
    case Path.extname(basename) do
      ".png" -> "image/png"
      ext when ext in [".jpg", ".jpeg"] -> "image/jpeg"
      ".webp" -> "image/webp"
    end
  end

  defp read_json(file) do
    @dir
    |> Path.join(file)
    |> File.read!()
    |> Jason.decode!()
  end
end
