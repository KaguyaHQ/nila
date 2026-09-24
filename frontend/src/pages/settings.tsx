import { WorkspaceError } from "@/components/workspace-error";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import {
  AlertDialog,
  AlertDialogContent,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogCancel,
  AlertDialogAction,
} from "@/components/ui/alert-dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { NativeSelect } from "@/components/ui/native-select";
import { Skeleton } from "@/components/ui/skeleton";
import { toast } from "@/components/ui/toast";
import { Shell } from "@/components/workspace-shell";
import {
  SettingsError,
  settingsRequest,
  type SettingsData,
  type SettingsResult,
} from "@/lib/settings-api";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams, useSearch } from "@tanstack/react-router";
import { Building2, LockKeyhole, Plus, UserRound, Users } from "lucide-react";
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";

const sections = [
  { id: "profile", label: "Profile", icon: UserRound },
  { id: "security", label: "Security", icon: LockKeyhole },
  { id: "workspace", label: "Firm", icon: Building2 },
  { id: "users", label: "Users", icon: Users },
] as const;

function useSettingsSave<T>(save: (values: T, signal: AbortSignal) => Promise<SettingsResult>) {
  const cache = useQueryClient();
  const request = useRef<AbortController | null>(null);
  useEffect(() => () => request.current?.abort(), []);
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: ({ values, controller }: { values: T; controller: AbortController }) =>
      save(values, controller.signal),
    onSuccess: (result, { controller }) => {
      if (controller.signal.aborted) return;
      if (result.redirect_to) {
        window.location.assign(result.redirect_to);
        return;
      }
      for (const key of ["settings", "clients", "sales", "purchases"])
        void cache.invalidateQueries({ queryKey: [key] });
      toast.add({ title: result.message, type: "success" });
    },
    onSettled: () => {
      request.current = null;
    },
  });
  return {
    ...mutation,
    submit: (values: T) => {
      if (request.current) return;
      const controller = new AbortController();
      request.current = controller;
      mutation.mutate({ values, controller });
    },
  };
}

type Field = {
  name: string;
  label: string;
  value?: string | null;
  type?: string;
  autoComplete?: string;
  required?: boolean;
  minLength?: number;
  options?: { label: string; value: string }[];
};
function SettingsForm({
  id,
  fields,
  action,
  save,
}: {
  id: string;
  fields: Field[];
  action: string;
  save: (values: Record<string, string>, signal: AbortSignal) => Promise<SettingsResult>;
}) {
  const mutation = useSettingsSave(save);
  const form = useRef<HTMLFormElement>(null);
  useEffect(() => {
    if (mutation.isSuccess) {
      form.current
        ?.querySelectorAll<HTMLInputElement>('input[type="password"]')
        .forEach((input) => {
          input.value = "";
        });
    }
  }, [mutation.isSuccess]);
  const errors = mutation.error instanceof SettingsError ? mutation.error.fields : {};
  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    mutation.submit(
      Object.fromEntries(new FormData(event.currentTarget)) as Record<string, string>,
    );
  }
  return (
    <form
      ref={form}
      id={id}
      onSubmit={submit}
      className="space-y-5"
      onChange={() => {
        if (mutation.isSuccess) mutation.reset();
      }}
    >
      <fieldset disabled={mutation.isPending} className="space-y-5">
        {fields.map((field) => (
          <div key={field.name} className="space-y-2">
            <Label htmlFor={`${id}-${field.name}`}>{field.label}</Label>
            {field.options ? (
              <NativeSelect
                id={`${id}-${field.name}`}
                name={field.name}
                defaultValue={field.value ?? "member"}
                aria-invalid={!!errors[field.name]}
              >
                {field.options.map((option) => (
                  <option key={option.value} value={option.value}>
                    {option.label}
                  </option>
                ))}
              </NativeSelect>
            ) : (
              <Input
                id={`${id}-${field.name}`}
                name={field.name}
                type={field.type ?? "text"}
                defaultValue={field.value ?? ""}
                required={field.required ?? true}
                autoComplete={field.autoComplete}
                minLength={field.minLength}
                aria-invalid={!!errors[field.name]}
                aria-describedby={errors[field.name] ? `${id}-${field.name}-error` : undefined}
              />
            )}
            {errors[field.name] && (
              <p id={`${id}-${field.name}-error`} className="text-sm text-destructive">
                {errors[field.name].join(", ")}
              </p>
            )}
          </div>
        ))}
        <Button type="submit">{mutation.isPending ? "Saving…" : action}</Button>
      </fieldset>
      {mutation.isError && (
        <p role="alert" className="text-sm text-destructive">
          {mutation.error.message}
        </p>
      )}
    </form>
  );
}

function Panel({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <Card className="gap-5 p-6 shadow-none">
      <div>
        <h2 className="font-medium">{title}</h2>
        {description && <p className="mt-1 text-sm text-muted-foreground">{description}</p>}
      </div>
      {children}
    </Card>
  );
}

export default function SettingsPage() {
  const { section = "profile" } = useParams({ from: "/settings/$section" });
  const query = useQuery({
    queryKey: ["settings"],
    queryFn: ({ signal }) => settingsRequest("getSettings", { signal }),
    refetchOnWindowFocus: false,
    retry: false,
  });
  if (query.isPending)
    return (
      <main className="mx-auto max-w-4xl space-y-6 p-12" aria-label="Loading settings">
        <Skeleton className="h-8 w-40" />
        <Skeleton className="h-80 w-full" />
      </main>
    );
  if (query.isError)
    return (
      <WorkspaceError
        title="Settings unavailable"
        message={query.error.message}
        needsSignIn={query.error instanceof SettingsError && query.error.status === 401}
        retry={() => {
          void query.refetch();
        }}
        backToClients={false}
      />
    );
  const data = query.data;
  const available = sections.filter((item) =>
    item.id === "workspace"
      ? data.can_manage_firm
      : item.id === "users"
        ? data.can_manage_users
        : true,
  );
  const current = available.find((item) => item.id === section);
  return (
    <Shell firm={data.user} clients={data.clients} settings={current?.label ?? "Unavailable"}>
      <div className="mx-auto max-w-5xl">
        <h1 className="mb-8 text-3xl font-semibold tracking-tight">Settings</h1>
        <div className="grid grid-cols-[180px_minmax(0,1fr)] items-start gap-10">
          <nav aria-label="Settings" className="space-y-1">
            {available.map((item) => (
              <Button
                key={item.id}
                variant="ghost"
                nativeButton={false}
                role="link"
                render={<Link to="/settings/$section" params={{ section: item.id }} />}
                aria-current={section === item.id ? "page" : undefined}
                className={`w-full justify-start ${section === item.id ? "bg-muted" : "text-muted-foreground"}`}
              >
                <item.icon />
                {item.label}
              </Button>
            ))}
          </nav>
          <div key={section} className="max-w-2xl space-y-6">
            {!current ? (
              <p role="alert">You don't have access to this settings page.</p>
            ) : section === "profile" ? (
              <Profile data={data} />
            ) : section === "security" ? (
              <Security />
            ) : section === "workspace" ? (
              <Panel title="Firm details" description="Shared details for your firm.">
                <SettingsForm
                  id="firm"
                  fields={[
                    { name: "name", label: "Firm name", value: data.firm.name },
                    {
                      name: "contact_phone",
                      label: "Contact phone",
                      type: "tel",
                      value: data.firm.contact_phone,
                      required: false,
                    },
                  ]}
                  action="Save changes"
                  save={(v, signal) =>
                    settingsRequest("updateSettingsFirm", {
                      body: { name: v.name, contact_phone: v.contact_phone },
                      signal,
                    })
                  }
                />
              </Panel>
            ) : (
              <Members data={data} />
            )}
          </div>
        </div>
      </div>
    </Shell>
  );
}

function Profile({ data }: { data: SettingsData }) {
  const params = useSearch({ from: "/settings/$section" });
  return (
    <>
      {params.email === "confirmed" && <p role="status">Your email has been updated.</p>}
      {params.email === "invalid" && (
        <p role="alert" className="text-destructive">
          Email change link is invalid or expired.
        </p>
      )}
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-semibold">{data.user.name}</h2>
          <p className="mt-1 text-sm text-muted-foreground">{data.user.email}</p>
        </div>
        <Badge variant="secondary">{data.user.role}</Badge>
      </div>
      <Panel title="Name" description="How your name appears across the firm.">
        <SettingsForm
          id="profile-name"
          fields={[{ name: "name", label: "Name", value: data.user.name, autoComplete: "name" }]}
          action="Save name"
          save={(v, signal) =>
            settingsRequest("updateSettingsName", { body: { name: v.name }, signal })
          }
        />
      </Panel>
      <Panel
        title="Email address"
        description="Your email changes only after you open the confirmation link."
      >
        <SettingsForm
          id="profile-email"
          fields={[
            { name: "email", label: "New email", type: "email", autoComplete: "email" },
            {
              name: "current_password",
              label: "Current password",
              type: "password",
              autoComplete: "current-password",
            },
          ]}
          action="Send confirmation link"
          save={(v, signal) =>
            settingsRequest("updateSettingsEmail", {
              body: { email: v.email, current_password: v.current_password },
              signal,
            })
          }
        />
      </Panel>
    </>
  );
}

function Security() {
  const cancelSignout = useRef<HTMLButtonElement>(null);
  const signoutTrigger = useRef<HTMLButtonElement>(null);
  const params = useSearch({ from: "/settings/$section" });
  const [open, setOpen] = useState(false);
  const signout = useSettingsSave((_: void, signal) =>
    settingsRequest("deleteSettingsSessions", { signal }),
  );
  return (
    <>
      {params.updated === "password" && <p role="status">Password updated.</p>}
      <Panel title="Password" description="Changing your password signs out your other sessions.">
        <SettingsForm
          id="password"
          fields={[
            {
              name: "current_password",
              label: "Current password",
              type: "password",
              autoComplete: "current-password",
            },
            {
              name: "password",
              label: "New password",
              type: "password",
              autoComplete: "new-password",
              minLength: 12,
            },
            {
              name: "password_confirmation",
              label: "Confirm new password",
              type: "password",
              autoComplete: "new-password",
            },
          ]}
          action="Update password"
          save={(v, signal) =>
            settingsRequest("updateSettingsPassword", {
              body: {
                current_password: v.current_password,
                password: v.password,
                password_confirmation: v.password_confirmation,
              },
              signal,
            })
          }
        />
      </Panel>
      <Panel title="Sessions" description="Sign out every browser and device, including this one.">
        <Button
          ref={signoutTrigger}
          variant="outline"
          className="w-fit"
          onClick={() => setOpen(true)}
        >
          Sign out everywhere
        </Button>
      </Panel>
      <AlertDialog
        open={open}
        onOpenChange={(value) => {
          if (!signout.isPending) setOpen(value);
        }}
      >
        <AlertDialogContent initialFocus={cancelSignout} finalFocus={signoutTrigger}>
          <AlertDialogHeader>
            <AlertDialogTitle>Sign out everywhere?</AlertDialogTitle>
            <AlertDialogDescription>
              You'll need to sign in again on this device too.
            </AlertDialogDescription>
          </AlertDialogHeader>
          {signout.isError && (
            <p role="alert" className="text-sm text-destructive">
              {signout.error.message}
            </p>
          )}
          <AlertDialogFooter>
            <AlertDialogCancel ref={cancelSignout} disabled={signout.isPending}>
              Cancel
            </AlertDialogCancel>
            <AlertDialogAction
              variant="destructive"
              disabled={signout.isPending}
              onClick={() => signout.submit()}
            >
              {signout.isPending ? "Signing out…" : "Sign out everywhere"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}

function Members({ data }: { data: SettingsData }) {
  const [invite, setInvite] = useState(false);
  return (
    <>
      <div className="flex items-center justify-between">
        <div>
          <h2 className="text-xl font-semibold">Users</h2>
          <p className="mt-1 text-sm text-muted-foreground">People who can access your firm.</p>
        </div>
        <Button onClick={() => setInvite(!invite)}>
          <Plus />
          {invite ? "Close invitation" : "Invite user"}
        </Button>
      </div>
      {invite && (
        <Panel
          title="Invite user"
          description="They'll receive a link to set their password and join."
        >
          <SettingsForm
            id="invite"
            fields={[
              { name: "name", label: "Name" },
              { name: "email", label: "Work email", type: "email" },
              { name: "role", label: "Role", value: "member", options: data.roles },
            ]}
            action="Send invitation"
            save={(v, signal) =>
              settingsRequest("inviteSettingsUser", {
                body: {
                  name: v.name,
                  email: v.email,
                  role: v.role as "owner" | "member" | "viewer",
                },
                signal,
              })
            }
          />
        </Panel>
      )}
      <div className="divide-y rounded-xl border bg-card">
        {data.members.map((member) => (
          <Member key={member.id} member={member} roles={data.roles} />
        ))}
      </div>
    </>
  );
}

function Member({
  member,
  roles,
}: {
  member: SettingsData["members"][number];
  roles: SettingsData["roles"];
}) {
  const mutation = useSettingsSave(
    (body: Parameters<typeof settingsRequest<"updateSettingsMember">>[1]["body"], signal) =>
      settingsRequest("updateSettingsMember", { id: member.id, body, signal }),
  );
  return (
    <div className="space-y-3 p-5">
      <div className="flex items-center gap-4">
        <div className="min-w-0 flex-1">
          <p className="font-medium">
            {member.name}
            {member.self && <span className="ml-2 text-xs text-muted-foreground">You</span>}
          </p>
          <p className="truncate text-sm text-muted-foreground">{member.email}</p>
        </div>
        <Badge variant="outline">
          {!member.active ? "Disabled" : member.invited ? "Invited" : "Active"}
        </Badge>
        <NativeSelect
          aria-label={`Role for ${member.name}`}
          className="w-36 shrink-0"
          value={member.role}
          disabled={!member.can_change_role || mutation.isPending}
          onChange={(event) =>
            mutation.submit({
              action: "role",
              role: event.target.value as "owner" | "admin" | "member" | "viewer",
            })
          }
        >
          {member.role === "admin" && <option value="admin">Admin</option>}
          {roles.map((role) => (
            <option key={role.value} value={role.value}>
              {role.label}
            </option>
          ))}
        </NativeSelect>
      </div>
      <div className="flex justify-end gap-2">
        {member.invited && (
          <Button
            size="sm"
            variant="ghost"
            disabled={mutation.isPending}
            onClick={() => mutation.submit({ action: "resend" })}
          >
            Resend invite
          </Button>
        )}
        {!member.self && (
          <Button
            size="sm"
            variant="outline"
            disabled={!member.can_toggle_active || mutation.isPending}
            onClick={() => mutation.submit({ action: "active", active: !member.active })}
          >
            {member.active ? "Disable" : "Enable"}
          </Button>
        )}
      </div>
      {mutation.isError && (
        <p role="alert" className="text-sm text-destructive">
          {mutation.error.message}
        </p>
      )}
    </div>
  );
}
