import { useEffect, useRef, useState, type FormEvent } from "react";
import { Link } from "react-router-dom";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, ArrowUpRight, FileText, Undo2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { ApiError } from "@/lib/sales-api";
import { decideSalesCheck, fetchSalesChecks, type MonthlySalesCheck, type MonthlySalesChecks } from "@/lib/sales-checks-api";
import { basePath, useSales } from "./live-sales";

const supportedChecks = new Set(["sequence_gaps", "pages_unaccounted", "evidence_unavailable"]);
const changedMessage = "This check changed. Review the updated check before confirming it again.";

export default function SalesChecks() {
  const workspace = useSales();
  const client = String(workspace.client.id);
  const period = workspace.period;
  const query = useQuery({
    queryKey: ["sales-checks", client, period],
    queryFn: ({ signal }) => fetchSalesChecks(client, period, signal),
    staleTime: 0,
    retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 1,
  });
  return <div className="mx-auto max-w-4xl space-y-6">
    <div><Link to={basePath(workspace)} className="mb-5 inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="size-4" /> Sales summary</Link><h1 id="monthly-checks-heading" tabIndex={-1} className="text-2xl font-semibold tracking-tight outline-none">Monthly checks</h1><p className="mt-2 text-sm text-muted-foreground">{workspace.client.name} · {workspace.month_label}</p></div>
    {query.isPending ? <p role="status" className="text-sm text-muted-foreground">Loading monthly checks…</p> : query.isError ? <div className="space-y-4"><p role="alert" className="text-sm text-destructive">{query.error.message}</p>{query.error instanceof ApiError && query.error.status === 401 ? <a href="/users/log_in" className="text-sm underline">Sign in</a> : <Button variant="outline" onClick={() => query.refetch()}>Try again</Button>}</div> : <ChecksList key={`${client}/${period}`} data={query.data} refreshing={query.isFetching} reload={() => query.refetch()} />}
  </div>;
}

function ChecksList({ data, refreshing, reload }: { data: MonthlySalesChecks; refreshing: boolean; reload: () => unknown }) {
  const cache = useQueryClient();
  const [selected, setSelected] = useState<MonthlySalesCheck | null>(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<{ target: string; message: string } | null>(null);
  const [notice, setNotice] = useState("");
  const [mustReview, setMustReview] = useState(false);
  const opener = useRef<HTMLButtonElement | null>(null);
  const operation = useRef<AbortController | null>(null);
  const pending = selected && data.checks.find(check => check.target === selected.target);
  const selectionCurrent = Boolean(selected?.basis && pending?.basis === selected.basis && pending?.status === "open");
  useEffect(() => () => operation.current?.abort(), []);

  function openConfirmation(check: MonthlySalesCheck, button: HTMLButtonElement) {
    opener.current = button;
    setSelected(check);
    setError(null);
    setMustReview(false);
    setDialogOpen(true);
  }
  async function decide(check: MonthlySalesCheck, action: "confirm" | "reopen") {
    if (operation.current || !data.can_edit || !check.basis || !supportedChecks.has(check.code)) return;
    const current = data.checks.find(item => item.target === check.target);
    if (!current || current.basis !== check.basis || current.status !== (action === "confirm" ? "open" : "resolved")) {
      setError({ target: check.target, message: changedMessage });
      setMustReview(true);
      reload();
      return;
    }
    const controller = new AbortController();
    operation.current = controller;
    setBusy(check.target);
    setError(null);
    setNotice("");
    try {
      const result = await decideSalesCheck(String(data.client.id), data.period, { target: check.target, basis: check.basis, action }, controller.signal);
      if (controller.signal.aborted) return;
      await cache.cancelQueries({ queryKey: ["sales-checks", String(data.client.id), data.period] });
      if (controller.signal.aborted) return;
      cache.setQueryData(["sales-checks", String(data.client.id), data.period], result);
      void cache.invalidateQueries({ queryKey: ["sales"] });
      void cache.invalidateQueries({ queryKey: ["sales-review"], refetchType: "none" });
      setNotice(action === "confirm" ? "Confirmation saved." : "Confirmation removed.");
      setDialogOpen(false);
    } catch (failure) {
      if (!controller.signal.aborted) {
        setError({ target: check.target, message: failure instanceof Error ? failure.message : "This decision could not be saved. Please try again." });
        if (failure instanceof ApiError && [403, 409, 422].includes(failure.status)) {
          setMustReview(true);
          reload();
        }
      }
    } finally {
      operation.current = null;
      if (!controller.signal.aborted) setBusy(null);
    }
  }
  function submit(event: FormEvent) {
    event.preventDefault();
    if (selected && selectionCurrent && !mustReview) void decide(selected, "confirm");
  }

  return <>
    {!data.can_edit && <p id="monthly-checks-lock" className="rounded-lg border bg-muted/40 px-4 py-3 text-sm">{data.lock_reason || "Your role allows viewing these checks, not changing them."}</p>}
    {notice && <p role="status" className="text-sm text-muted-foreground">{notice}</p>}
    {data.checks.length === 0 ? <p className="rounded-xl border bg-card px-5 py-10 text-center text-sm text-muted-foreground">No sequence or source-page checks to review.</p> : <div className="space-y-4">{data.checks.map(check => {
      const supported = supportedChecks.has(check.code);
      const canAct = data.can_edit && Boolean(check.basis) && !refreshing && busy === null;
      return <section key={check.target} className="space-y-4 rounded-xl border bg-card p-5" aria-label={check.title}>
        <div className="flex flex-wrap items-start justify-between gap-3"><h2 className="text-sm font-semibold">{check.title}</h2><Badge variant="secondary" className={check.status === "open" ? "bg-amber-50 font-normal text-amber-800" : "font-normal"}>{check.status === "resolved" ? "Confirmed" : "Needs review"}</Badge></div>
        <p className="text-sm leading-6 text-muted-foreground">{check.message}</p>
        {check.sources.length > 0 && <div className="space-y-2">{check.sources.map(source => <a key={`${source.id}:${source.url}`} href={source.url} target="_blank" rel="noopener noreferrer" className="flex w-fit max-w-full items-start gap-2 text-sm underline underline-offset-4"><FileText className="mt-0.5 size-4 shrink-0" /><span className="break-words">{source.name}<span className="sr-only"> (original source, new tab)</span></span><ArrowUpRight className="mt-0.5 size-3.5 shrink-0" /></a>)}</div>}
        {check.action_paths.length > 0 && <div className="flex flex-wrap gap-x-5 gap-y-2">{check.action_paths.map(path => <Link key={`${path.label}:${path.path}`} to={path.path} className="text-sm underline underline-offset-4">{path.label}</Link>)}</div>}
        {error?.target === check.target && !dialogOpen && <p role="alert" className="text-sm text-destructive">{error.message}</p>}
        {supported && check.confirm_label && <div className="flex justify-end"><Button variant="outline" size="sm" className="h-auto min-h-8 max-w-full py-2 text-left whitespace-normal" disabled={!canAct} aria-describedby={!data.can_edit ? "monthly-checks-lock" : undefined} onClick={event => {
          if (check.status === "resolved") void decide(check, "reopen");
          else openConfirmation(check, event.currentTarget);
        }}>{check.status === "resolved" && <Undo2 />}{busy === check.target ? "Saving…" : check.status === "resolved" ? "Undo confirmation" : check.confirm_label}</Button></div>}
      </section>;
    })}</div>}

    <Dialog open={dialogOpen} onOpenChange={open => { if (!open && !busy) setDialogOpen(false); }}>
      <DialogContent finalFocus={() => opener.current?.isConnected && !opener.current.disabled ? opener.current : document.getElementById("monthly-checks-heading")} showCloseButton={!busy}>
        <DialogHeader><DialogTitle>{selected?.title ?? "Monthly check"}</DialogTitle><DialogDescription>Confirm only after checking the source records for this month.</DialogDescription></DialogHeader>
        <form onSubmit={submit} className="space-y-4">
          {error?.target === selected?.target && <p role="alert" className="text-sm text-destructive">{error?.message}</p>}
          {dialogOpen && (mustReview || !selectionCurrent) && data.can_edit && <p className="text-sm leading-6 text-muted-foreground">Close this dialog and review the updated check before confirming again.</p>}
          {!data.can_edit && <p className="text-sm text-muted-foreground">{data.lock_reason || "This month is read-only."}</p>}
          <p className="text-sm leading-6">{selected?.confirmation_text}</p>
          <div className="flex flex-wrap justify-end gap-2 border-t pt-4"><Button type="button" variant="outline" disabled={busy !== null} onClick={() => setDialogOpen(false)}>{mustReview ? "Close and review" : "Cancel"}</Button><Button type="submit" className="h-auto min-h-9 max-w-full py-2 text-left whitespace-normal" disabled={busy !== null || !data.can_edit || refreshing || !selectionCurrent || mustReview}>{busy ? "Saving…" : selected?.confirm_label}</Button></div>
        </form>
      </DialogContent>
    </Dialog>
  </>;
}
