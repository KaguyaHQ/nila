import { useEffect, useRef, useState, type FormEvent } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { toast } from "@/components/ui/toast";

type Invitation = import("@/lib/generated/workspace").components["schemas"]["Invitation"];

export function BusinessInvitation({ clientId }: { clientId: number }) {
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [result, setResult] = useState<Invitation | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const operation = useRef<AbortController | null>(null);
  const link = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setName("");
    setEmail("");
    setResult(null);
    setError("");
    setBusy(false);
    setCopied(false);
    return () => {
      operation.current?.abort();
      operation.current = null;
    };
  }, [clientId]);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (operation.current) return;
    const controller = new AbortController();
    operation.current = controller;
    setBusy(true);
    setError("");
    setResult(null);
    setCopied(false);
    try {
      const response = await fetch(`/api/workspace/clients/${clientId}/business-invitation`, {
        method: "POST",
        credentials: "same-origin",
        signal: controller.signal,
        headers: {
          Accept: "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token":
            document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "",
        },
        body: JSON.stringify({
          invitation: { name, email },
        } satisfies import("@/lib/generated/workspace").components["schemas"]["InvitationInput"]),
      });
      const data = await response.json();
      if (!response.ok)
        throw new Error(
          typeof data.error === "string"
            ? data.error
            : "Couldn't create the invitation. Please try again.",
        );
      if (!controller.signal.aborted) setResult(data);
    } catch (failure) {
      if (!controller.signal.aborted)
        setError(
          failure instanceof Error
            ? failure.message
            : "Couldn't create the invitation. Please try again.",
        );
    } finally {
      if (operation.current === controller) operation.current = null;
      if (!controller.signal.aborted) setBusy(false);
    }
  }

  async function copyLink() {
    if (!result) return;
    try {
      await navigator.clipboard.writeText(result.invitation_url);
      setCopied(true);
      toast.add({ title: "Invitation link copied.", type: "success" });
    } catch {
      link.current?.focus();
      link.current?.select();
      setError("Copy the selected link and share it with your client.");
    }
  }

  return (
    <section
      aria-labelledby="business-invitation-heading"
      className="space-y-5 rounded-xl border bg-card p-6"
    >
      <div className="space-y-2">
        <h2 id="business-invitation-heading" className="font-semibold">
          Client invoicing access
        </h2>
        <p className="text-sm text-muted-foreground">
          Invite your client to create service invoices. Issued invoices appear in your sales
          working.
        </p>
      </div>
      <form id="business-invitation-form" onSubmit={submit} className="space-y-4">
        <div className="space-y-2">
          <label htmlFor="business-invitation-name" className="text-sm font-medium">
            Contact name
          </label>
          <Input
            id="business-invitation-name"
            autoComplete="name"
            required
            maxLength={255}
            disabled={busy}
            value={name}
            onChange={(event) => {
              setName(event.target.value);
              setResult(null);
            }}
          />
        </div>
        <div className="space-y-2">
          <label htmlFor="business-invitation-email" className="text-sm font-medium">
            Email
          </label>
          <Input
            id="business-invitation-email"
            type="email"
            autoComplete="email"
            required
            maxLength={255}
            disabled={busy}
            value={email}
            onChange={(event) => {
              setEmail(event.target.value);
              setResult(null);
            }}
          />
        </div>
        <Button type="submit" variant="outline" disabled={busy}>
          {busy ? "Creating link…" : "Create invitation link"}
        </Button>
      </form>
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      {result && (
        <div className="space-y-3">
          <p role="status" className="text-sm">
            {result.already_active
              ? `${result.email} already has access. Share this sign-in link.`
              : `Share this invitation with ${result.email}. The link expires in 14 days.`}
          </p>
          <label htmlFor="business-invitation-link" className="sr-only">
            Invitation link
          </label>
          <Input
            ref={link}
            id="business-invitation-link"
            readOnly
            value={result.invitation_url}
            onFocus={(event) => event.target.select()}
          />
          <Button type="button" variant="outline" onClick={copyLink}>
            {copied ? "Copied" : "Copy link"}
          </Button>
        </div>
      )}
    </section>
  );
}
