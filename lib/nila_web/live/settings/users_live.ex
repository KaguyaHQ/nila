defmodule NilaWeb.Settings.UsersLive do
  use NilaWeb, :live_view

  alias Nila.Accounts
  alias Nila.Accounts.Policy
  alias Nila.Orgs

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Users")
      |> assign(:settings_section, :users)
      |> assign(:show_invite, false)
      |> assign_invite_form()
      |> load_members()

    {:ok, socket}
  end

  @impl true
  def handle_event("open_invite", _params, socket) do
    {:noreply, assign(socket, :show_invite, true)}
  end

  @impl true
  def handle_event("close_invite", _params, socket) do
    {:noreply, socket |> assign(:show_invite, false) |> assign_invite_form()}
  end

  @impl true
  def handle_event("validate_invite", %{"invite" => params}, socket) do
    changeset = params |> Accounts.change_invite() |> Map.put(:action, :validate)
    {:noreply, assign(socket, :invite_form, to_form(changeset, as: :invite))}
  end

  @impl true
  def handle_event("send_invite", %{"invite" => params}, socket) do
    with :ok <- ensure_can_manage(socket) do
      changeset = params |> Accounts.change_invite() |> Map.put(:action, :validate)

      if changeset.valid? do
        attrs = Ecto.Changeset.apply_changes(changeset)
        org = socket.assigns.current_scope.current_org

        case Accounts.invite_user(org, attrs, &url(~p"/users/invite/#{&1}")) do
          {:ok, user} ->
            {:noreply,
             socket
             |> put_flash(:info, "Invitation sent to #{user.email}.")
             |> assign(:show_invite, false)
             |> assign_invite_form()
             |> load_members()}

          {:error, :already_member} ->
            {:noreply, put_flash(socket, :error, "That person is already in this firm.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not send the invitation.")}
        end
      else
        {:noreply, assign(socket, :invite_form, to_form(changeset, as: :invite))}
      end
    end
  end

  @impl true
  def handle_event("change_role", %{"membership_id" => id, "role" => role}, socket) do
    with :ok <- ensure_can_manage(socket) do
      membership = Enum.find(socket.assigns.members, &(to_string(&1.id) == id))

      case membership && Orgs.update_membership_role(membership, role) do
        {:ok, _membership} ->
          {:noreply, socket |> put_flash(:info, "Role updated.") |> load_members()}

        {:error, :last_owner} ->
          {:noreply,
           socket
           |> put_flash(:error, "You can't remove the firm's last owner.")
           |> load_members()}

        _ ->
          {:noreply, socket |> put_flash(:error, "Could not update the role.") |> load_members()}
      end
    end
  end

  @impl true
  def handle_event("toggle_active", %{"user_id" => user_id}, socket) do
    with :ok <- ensure_can_manage(socket) do
      members = socket.assigns.members
      scope = socket.assigns.current_scope
      member = Enum.find(members, &(to_string(&1.user_id) == user_id))

      cond do
        is_nil(member) ->
          {:noreply, socket}

        member.user_id == scope.user.id ->
          {:noreply, put_flash(socket, :error, "You can't disable your own account.")}

        disabling_last_owner?(members, member) ->
          {:noreply, put_flash(socket, :error, "You can't disable the firm's last owner.")}

        true ->
          {:ok, _user} = Accounts.set_user_active(member.user, not member.user.active)

          flash = if member.user.active, do: "User disabled.", else: "User enabled."
          {:noreply, socket |> put_flash(:info, flash) |> load_members()}
      end
    end
  end

  @impl true
  def handle_event("resend_invite", %{"user_id" => user_id}, socket) do
    with :ok <- ensure_can_manage(socket) do
      member = Enum.find(socket.assigns.members, &(to_string(&1.user_id) == user_id))
      org = socket.assigns.current_scope.current_org

      if member do
        {:ok, _user} = Accounts.resend_invite(member.user, org, &url(~p"/users/invite/#{&1}"))
        {:noreply, put_flash(socket, :info, "Invitation resent to #{member.user.email}.")}
      else
        {:noreply, socket}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.settings
      flash={@flash}
      current_scope={@current_scope}
      active_section={@settings_section}
    >
      <div id="settings-users" class="space-y-section">
        <.page_header eyebrow="Settings" title="Users">
          Everyone who works at this firm. Owners and admins manage access;
          operators run the day-to-day; viewers read and export.
          <:actions>
            <.button id="invite-user-button" phx-click="open_invite" variant="primary">
              <.icon name="hero-user-plus" class="size-4" /> Invite user
            </.button>
          </:actions>
        </.page_header>

        <.data_table
          id="members"
          rows={@members}
          row_id={fn member -> "member-#{member.id}" end}
          empty?={@members == []}
          min_width="min-w-[640px]"
        >
          <:col :let={member} label="Name">
            <span class="text-base-content font-medium">
              {member.user.name}
              <span
                :if={member.user_id == @current_scope.user.id}
                class="text-ink-subtle text-meta ml-1 font-normal"
              >
                (you)
              </span>
            </span>
          </:col>
          <:col :let={member} label="Email">
            <span class="text-ink-muted">{member.user.email}</span>
          </:col>
          <:col :let={member} label="Role">
            <form
              id={"role-form-#{member.id}"}
              phx-change="change_role"
              class="inline-flex flex-col gap-1"
            >
              <input type="hidden" name="membership_id" value={member.id} />
              <select
                name="role"
                class="select select-sm"
                disabled={locked_owner?(@members, member)}
                aria-label={"Role for #{member.user.name}"}
              >
                <option
                  :for={{label, value} <- Policy.assignable_roles()}
                  value={value}
                  selected={member.role == value}
                >
                  {label}
                </option>
              </select>
              <span class="text-ink-muted text-meta max-w-56">
                {Policy.role_description(member.role)}
              </span>
            </form>
          </:col>
          <:col :let={member} label="Status">
            <% {variant, label} = status_badge(member.user) %>
            <.badge variant={variant}>{label}</.badge>
          </:col>
          <:col :let={member} label="Actions" align="right">
            <div class="flex items-center justify-end gap-3">
              <button
                :if={invited?(member.user)}
                type="button"
                phx-click="resend_invite"
                phx-value-user_id={member.user_id}
                class="text-meta text-primary font-semibold transition hover:underline"
              >
                Resend invite
              </button>
              <button
                :if={member.user_id != @current_scope.user.id}
                type="button"
                phx-click="toggle_active"
                phx-value-user_id={member.user_id}
                class="hover:text-ink text-ink-muted text-meta font-semibold transition"
              >
                {if member.user.active, do: "Disable", else: "Enable"}
              </button>
            </div>
          </:col>
          <:empty>No members yet.</:empty>
        </.data_table>
      </div>

      <.modal :if={@show_invite} id="invite-modal" title="Invite user" on_close="close_invite">
        <.form
          for={@invite_form}
          id="invite-form"
          phx-change="validate_invite"
          phx-submit="send_invite"
          class="space-y-block"
        >
          <.input field={@invite_form[:name]} label="Name" required />
          <.input field={@invite_form[:email]} type="email" label="Work email" required />
          <.input
            field={@invite_form[:role]}
            type="select"
            label="Role"
            options={Policy.assignable_roles()}
          />
          <p class="text-ink-muted text-meta">
            They'll get an email with a link to set a password and join. Owners and
            admins manage the firm; operators run the day-to-day work and approvals;
            viewers can only read and export.
          </p>
          <div class="flex justify-end gap-2">
            <.button
              type="button"
              phx-click="close_invite"
              variant="ghost"
              size="sm"
            >
              Cancel
            </.button>
            <.button type="submit" variant="primary">Send invitation</.button>
          </div>
        </.form>
      </.modal>
    </Layouts.settings>
    """
  end

  defp ensure_can_manage(socket) do
    if Policy.can?(socket.assigns.current_scope, :manage_users) do
      :ok
    else
      {:noreply, put_flash(socket, :error, "You don't have access to manage users.")}
    end
  end

  defp assign_invite_form(socket) do
    assign(
      socket,
      :invite_form,
      to_form(Accounts.change_invite(%{"role" => "member"}), as: :invite)
    )
  end

  defp load_members(%{assigns: %{current_scope: %{current_org: nil}}} = socket) do
    assign(socket, :members, [])
  end

  defp load_members(socket) do
    org = socket.assigns.current_scope.current_org
    assign(socket, :members, Orgs.list_memberships(org.id))
  end

  defp invited?(user), do: user.active and is_nil(user.hashed_password)

  defp status_badge(%{active: false}), do: {"neutral", "Disabled"}
  defp status_badge(%{hashed_password: nil}), do: {"warning", "Invited"}
  defp status_badge(_user), do: {"success", "Active"}

  defp owner_count(members), do: Enum.count(members, &(&1.role == "owner"))

  defp locked_owner?(members, member), do: member.role == "owner" and owner_count(members) <= 1

  defp disabling_last_owner?(members, member) do
    member.role == "owner" and member.user.active and
      Enum.count(members, &(&1.role == "owner" and &1.user.active)) <= 1
  end
end
