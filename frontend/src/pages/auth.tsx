import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { Eye, EyeOff } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader } from "@/components/ui/card";
import { Checkbox } from "@/components/ui/checkbox";
import { Field, FieldError, FieldGroup, FieldLabel } from "@/components/ui/field";
import { Input } from "@/components/ui/input";
import { useToastManager } from "@/components/ui/toast";

export type AuthPageData = {
  kind: "login" | "forgot" | "reset" | "invite" | "confirmation" | "business_signup";
  action: string;
  email?: string | null;
  name?: string | null;
  info?: string | null;
  error?: string | null;
  valid?: boolean;
  confirmed?: boolean;
  continueTo?: string;
  business_name?: string | null;
  gstin?: string | null;
  errors?: Record<string, string[]>;
  users?: { name: string; email: string }[];
};

// Composition adapted from shadcn's Base UI login-03 block.
// Native POSTs intentionally keep session creation and redirects in Phoenix.
export default function AuthPage({ data }: { data: AuthPageData }) {
  const { add } = useToastManager();
  const notified = useRef(false);
  useEffect(() => {
    if (data.info && !notified.current) {
      notified.current = true;
      add({ title: data.info, type: "success" });
    }
  }, [data.info, add]);
  const invalid = (data.kind === "reset" || data.kind === "invite") && !data.valid;
  const title = invalid
    ? `This ${data.kind === "invite" ? "invite" : "reset"} link is no longer valid`
    : {
        login: "Sign in to Nila",
        forgot: "Reset your password",
        reset: "Choose a new password",
        invite: "Welcome to Nila",
        confirmation: data.confirmed ? "Email verified" : "Verify your email",
        business_signup: "Create your business account",
      }[data.kind];
  const description = invalid
    ? data.kind === "invite"
      ? "It may have expired or already been used. Ask for a new invitation."
      : "It may have expired or already been used. Request a new reset link."
    : {
        login: "Use your work email and password.",
        forgot: "Enter your work email to request reset instructions.",
        reset: "Use at least 8 characters. Sign in again after the reset.",
        invite: `Create a password for ${data.email} to accept your invitation.`,
        confirmation: data.confirmed
          ? `${data.email} is verified.`
          : `Open the verification email sent to ${data.email}.`,
        business_signup: "Enter your business and owner details to get started.",
      }[data.kind];
  return (
    <main className="flex min-h-svh flex-col items-center justify-center gap-6 bg-muted p-6">
      <div className="flex w-full max-w-sm flex-col gap-6">
        <a
          href="/"
          aria-label="Nila home"
          className="self-center font-brand text-4xl font-semibold tracking-tight"
        >
          nila
        </a>
        <Card>
          <CardHeader className="text-center">
            <h1 className="text-xl font-semibold">{title}</h1>
            <CardDescription>{description}</CardDescription>
          </CardHeader>
          <CardContent className="space-y-5">
            {data.error && (
              <p role="alert" className="text-sm text-destructive">
                {data.error}
              </p>
            )}
            {invalid ? (
              <Button
                className="w-full"
                nativeButton={false}
                render={
                  <a href={data.kind === "reset" ? "/users/reset_password" : "/users/log_in"} />
                }
              >
                {data.kind === "reset" ? "Request a new link" : "Go to sign in"}
              </Button>
            ) : data.kind === "confirmation" ? (
              data.confirmed ? (
                <Button className="w-full" nativeButton={false} role="link" render={<a href={data.continueTo ?? "/app"} />}>
                  Continue to Nila
                </Button>
              ) : (
                <AuthForm action="/users/confirm" label="Resend verification email" />
              )
            ) : (
              <AuthForm
                action={data.action}
                label={
                  {
                    login: "Sign in",
                    forgot: "Send reset instructions",
                    reset: "Reset password",
                    invite: "Set password and sign in",
                    business_signup: "Create business account",
                  }[data.kind]
                }
              >
                {(data.kind === "login" || data.kind === "forgot") && (
                  <Field>
                    <FieldLabel htmlFor="user_email">Work email</FieldLabel>
                    <Input
                      id="user_email"
                      name="user[email]"
                      type="email"
                      autoComplete="username"
                      defaultValue={data.email ?? ""}
                      required
                    />
                  </Field>
                )}
                {data.kind === "business_signup" && (
                  <>
                    <TextField name="business[name]" id="business_name" label="Business name" autoComplete="organization" value={data.business_name ?? ""} errors={data.errors?.business_name} />
                    <TextField name="business[gstin]" id="business_gstin" label="GSTIN" autoComplete="off" value={data.gstin ?? ""} errors={data.errors?.gstin} />
                    <TextField name="user[name]" id="user_name" label="Your name" autoComplete="name" value={data.name ?? ""} errors={data.errors?.name} />
                    <TextField name="user[email]" id="user_email" label="Email" type="email" autoComplete="email" value={data.email ?? ""} errors={data.errors?.email} />
                  </>
                )}
                {data.kind !== "forgot" && data.kind !== "business_signup" && (
                  <PasswordField
                    name="password"
                    label={data.kind === "login" ? "Password" : "New password"}
                    current={data.kind === "login"}
                    errors={data.errors?.password}
                  />
                )}
                {data.kind === "business_signup" && (
                  <PasswordField name="password" label="Password" errors={data.errors?.password} />
                )}
                {(data.kind === "reset" || data.kind === "invite" || data.kind === "business_signup") && (
                  <PasswordField
                    name="password_confirmation"
                    label="Confirm password"
                    errors={data.errors?.password_confirmation}
                  />
                )}
                {data.kind === "login" && (
                  <Field orientation="horizontal">
                    <Checkbox id="remember" name="user[remember_me]" value="true" />
                    <FieldLabel htmlFor="remember">Keep me signed in</FieldLabel>
                  </Field>
                )}
              </AuthForm>
            )}
            {data.kind === "login" ? (
              <p className="text-center text-sm text-muted-foreground">
                <a href="/users/business_sign_up" className="underline underline-offset-4">Create a business account</a>
                <span className="mx-2">·</span>
                <a href="/contact" className="underline underline-offset-4">CA / firm? Arrange a test</a>
              </p>
            ) : data.kind === "confirmation" ? (
              <form method="post" action="/users/log_out">
                <Csrf />
                <input type="hidden" name="_method" value="delete" />
                <Button variant="ghost" type="submit" className="w-full">
                  Sign out
                </Button>
              </form>
            ) : (
              <p className="text-center text-sm">
                <a href="/users/log_in" className="underline underline-offset-4">
                  Back to sign in
                </a>
              </p>
            )}
          </CardContent>
        </Card>
        {!!data.users?.length && (
          <section aria-label="Quick login" className="space-y-2">
            <p className="text-center text-xs text-muted-foreground">Development quick login</p>
            <div className="flex flex-wrap justify-center gap-2">
              {data.users.map((user) => (
                <form key={user.email} method="post" action="/users/log_in">
                  <Csrf />
                  <input type="hidden" name="dev_login" value="true" />
                  <input type="hidden" name="email" value={user.email} />
                  <Button type="submit" size="sm" variant="outline">
                    {user.name}
                  </Button>
                </form>
              ))}
            </div>
          </section>
        )}
      </div>
    </main>
  );
}
function TextField({ name, id, label, type = "text", autoComplete, value, errors }: { name: string; id: string; label: string; type?: string; autoComplete?: string; value?: string; errors?: string[] }) {
  return (
    <Field data-invalid={!!errors?.length}>
      <FieldLabel htmlFor={id}>{label}</FieldLabel>
      <Input id={id} name={name} type={type} autoComplete={autoComplete} defaultValue={value} required aria-invalid={!!errors?.length} aria-describedby={errors?.length ? `${id}-error` : undefined} />
      <FieldError id={`${id}-error`} errors={errors?.map((message) => ({ message }))} />
    </Field>
  );
}
function Csrf() {
  return (
    <input
      type="hidden"
      name="_csrf_token"
      value={document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""}
    />
  );
}
function AuthForm({
  action,
  label,
  children,
}: {
  action: string;
  label: string;
  children?: ReactNode;
}) {
  const locked = useRef(false);
  const [pending, setPending] = useState(false);
  useEffect(() => {
    const restore = () => {
      locked.current = false;
      setPending(false);
    };
    window.addEventListener("pageshow", restore);
    return () => window.removeEventListener("pageshow", restore);
  }, []);
  function submit(event: FormEvent) {
    if (locked.current) {
      event.preventDefault();
      return;
    }
    locked.current = true;
    setPending(true);
  }
  return (
    <form method="post" action={action} onSubmit={submit}>
      <Csrf />
      <FieldGroup>
        {children}
        <Button type="submit" disabled={pending} className="w-full">
          {pending ? "Please wait…" : label}
        </Button>
      </FieldGroup>
    </form>
  );
}
function PasswordField({
  name,
  label,
  current = false,
  errors,
}: {
  name: string;
  label: string;
  current?: boolean;
  errors?: string[];
}) {
  const [shown, setShown] = useState(false);
  const id = `user_${name}`;
  return (
    <Field data-invalid={!!errors?.length}>
      <div className="flex items-center justify-between gap-2">
        <FieldLabel htmlFor={id}>{label}</FieldLabel>
        {current && (
          <a href="/users/reset_password" className="text-xs underline underline-offset-4">
            Forgot password?
          </a>
        )}
      </div>
      <div className="relative">
        <Input
          id={id}
          name={`user[${name}]`}
          type={shown ? "text" : "password"}
          autoComplete={current ? "current-password" : "new-password"}
          minLength={current ? undefined : 8}
          required
          aria-invalid={!!errors?.length}
          aria-describedby={errors?.length ? `${id}-error` : undefined}
          className="pr-10"
        />
        <Button
          type="button"
          variant="ghost"
          size="icon-sm"
          className="absolute right-1 top-1/2 -translate-y-1/2"
          aria-label={`${shown ? "Hide" : "Show"} ${label.toLowerCase()}`}
          aria-controls={id}
          aria-pressed={shown}
          onClick={() => setShown(!shown)}
        >
          {shown ? <EyeOff /> : <Eye />}
        </Button>
      </div>
      <FieldError id={`${id}-error`} errors={errors?.map((message) => ({ message }))} />
    </Field>
  );
}
