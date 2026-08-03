defmodule Nila.Release do
  @moduledoc """
  Database tasks for the compiled production release, where Mix is unavailable.

  Invoked from `rel/overlays/bin/migrate` (and via `bin/nila eval`):

      /app/bin/nila eval "Nila.Release.migrate"

  `deploy.sh` runs `bin/migrate` before starting the server, so each deploy
  applies pending migrations. Keep migrations backward-compatible.
  """
  @app :nila

  alias Nila.Accounts
  alias Nila.Accounts.User
  alias Nila.Integrations
  alias Nila.Orgs
  alias Nila.Orgs.{Membership, Org}
  alias Nila.Repo

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc "Bootstraps a direct password-based owner account for operations and development."
  def create_owner(attrs) when is_map(attrs) do
    start_app()

    Repo.transact(fn ->
      with {:ok, user} <- get_or_create_user(attrs),
           {:ok, org} <- get_or_create_org(attrs),
           {:ok, membership} <- add_owner(org, user) do
        {:ok, %{user: user, org: org, membership: membership}}
      end
    end)
  end

  @doc "Provisions a customer firm and emails its first owner a setup invitation."
  def invite_firm(attrs) when is_map(attrs) do
    start_app()

    Accounts.provision_firm(
      %{name: attrs |> fetch_attr!(:firm) |> String.trim()},
      %{
        name: attrs |> fetch_attr!(:name) |> String.trim(),
        email: attrs |> fetch_attr!(:email) |> String.trim()
      },
      &invite_url/1
    )
  end

  @doc "Connects a WhatsApp phone-number ID using WHATSAPP_ACCESS_TOKEN."
  def provision_whatsapp(attrs) when is_map(attrs) do
    start_app()

    attrs
    |> Map.put(:access_token, System.fetch_env!("WHATSAPP_ACCESS_TOKEN"))
    |> Integrations.provision_whatsapp()
  end

  defp invite_url(token), do: NilaWeb.Endpoint.url() <> "/users/invite/" <> token

  defp get_or_create_user(attrs) do
    email = fetch_attr!(attrs, :email) |> String.trim() |> String.downcase()

    case Repo.get_by(User, email: email) do
      nil ->
        attrs
        |> take_attrs([:name, :password])
        |> Map.put(:email, email)
        |> Accounts.register_user()

      %User{} = user ->
        {:ok, user}
    end
  end

  defp get_or_create_org(attrs) do
    name = fetch_attr!(attrs, :org_name)

    case Repo.get_by(Org, name: name) do
      nil ->
        attrs
        |> take_attrs([:legal_name, :gstin])
        |> Map.put(:name, name)
        |> Orgs.create_org()

      %Org{} = org ->
        {:ok, org}
    end
  end

  defp add_owner(%Org{} = org, %User{} = user) do
    case Repo.get_by(Membership, org_id: org.id, user_id: user.id) do
      %Membership{role: "owner"} = membership ->
        {:ok, membership}

      %Membership{} = membership ->
        Orgs.update_membership_role(membership, "owner")

      nil ->
        case Orgs.add_user(org, user.id, "owner") do
          {:ok, membership} ->
            {:ok, membership}

          {:error, changeset} ->
            if membership_taken?(changeset), do: {:ok, :already_owner}, else: {:error, changeset}
        end
    end
  end

  defp fetch_attr!(attrs, key) do
    Map.get(attrs, key) || Map.fetch!(attrs, Atom.to_string(key))
  end

  defp take_attrs(attrs, keys) do
    Map.new(keys, fn key -> {key, Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))} end)
  end

  defp membership_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {field, {_msg, opts}} ->
      field in [:org_id, :user_id] and Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end

  defp start_app do
    {:ok, _} = Application.ensure_all_started(@app)
  end
end
