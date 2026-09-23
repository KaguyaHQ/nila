import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, ChevronLeft, ChevronRight, ExternalLink } from "lucide-react";
import { ShortcutHelpButton, navigationShortcutBlocked } from "@/components/keyboard-shortcuts";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { NativeSelect } from "@/components/ui/native-select";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { Table, TableHeader, TableHead, TableBody, TableRow, TableCell } from "@/components/ui/table";
import { fetchPurchaseReview, savePurchaseTreatment, recordPurchaseDocument, PurchaseReviewError, type PurchaseReviewData, type TreatmentValues, type TreatmentChoice } from "@/lib/purchase-review-api";

const choices: { id: TreatmentChoice; label: string }[] = [{ id: "claim", label: "Claim this month" }, { id: "later", label: "Claim later" }, { id: "exclude", label: "Exclude" }, { id: "split", label: "Split amounts" }];
const blankValues = (): TreatmentValues => ({ choice: null, later_reason: "", exclude_reason: "", note: "", split: { claim: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" }, later: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" }, exclude: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" } } });

export default function PurchaseReview() {
  const { clientId = "", period = "", itemId = "" } = useParams();
  const [params] = useSearchParams();
  const filter = params.get("filter") ?? "needs_review";
  const q = (params.get("q") ?? "").slice(0, 200);
  const queryKey = ["purchase-review", clientId, period, itemId, filter, q];
  const query = useQuery({ queryKey, queryFn: ({ signal }) => fetchPurchaseReview(clientId, period, itemId, filter, q, signal), staleTime: 0, retry: false });
  const back = `/gst/${clientId}/${period}/purchases`;
  if (query.isPending) return <main className="p-10"><p role="status">Loading purchase review…</p></main>;
  if (query.isError) return <main className="mx-auto max-w-xl space-y-5 px-6 py-20"><h1 className="text-2xl font-semibold">Purchase review unavailable</h1><p role="alert">{query.error.message}</p><Button onClick={() => query.refetch()}>Try again</Button><Link to={back} className="ml-4 underline">Back to purchases</Link></main>;
  return <Review key={`${clientId}/${period}/${itemId}/${filter}/${q}`} data={query.data} queryKey={queryKey} refreshing={query.isFetching} refresh={() => query.refetch()} />;
}

function Review({ data, queryKey, refreshing, refresh }: { data: PurchaseReviewData; queryKey: string[]; refreshing: boolean; refresh: () => Promise<unknown> }) {
  const navigate = useNavigate();
  const cache = useQueryClient();
  const [params] = useSearchParams();
  const [dialogOpen, setDialogOpen] = useState(false);
  const [values, setValues] = useState<TreatmentValues>(blankValues);
  const [saved, setSaved] = useState("");
  const opener = useRef<HTMLButtonElement | null>(null);
  const operation = useRef<AbortController | null>(null);
  const openingCases = useRef<PurchaseReviewData["cases"]>([]);
  const base = `/gst/${data.client.id}/${data.period}/purchases`;
  const item = data.item;
  const position = data.queue.findIndex(row => row.id === item?.id);
  const previous = data.queue[position - 1];
  const next = data.queue[position + 1];
  const ids = item?.case_ids ?? data.queue[position]?.case_ids ?? [];
  const cases = data.cases.filter(entry => ids.includes(entry.id));
  const blocked = !data.can_edit || item?.pairing_pending || cases.length === 0 || cases.some(entry => !entry.available);
  function go(id: string | undefined) {
    if (!id || busy || dialogOpen) return;
    navigate(`${base}/review/${encodeURIComponent(id)}?${params}`);
  }
  useEffect(() => () => operation.current?.abort(), []);
  useEffect(() => { document.title = `${item ? `Purchase ${item.number}` : "Purchase review"} · Nila`; }, [item]);
  useEffect(() => {
    function keyboard(event: KeyboardEvent) {
      if (navigationShortcutBlocked(event) || event.shiftKey || busy || dialogOpen || !event.altKey || event.ctrlKey || event.metaKey) return;
      const target = event.target;
      if (target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|SELECT|TEXTAREA)$/.test(target.tagName) || target.closest('[role="dialog"]'))) return;
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") { event.preventDefault(); go(event.key === "ArrowLeft" ? previous?.id : next?.id); }
    }
    window.addEventListener("keydown", keyboard);
    return () => window.removeEventListener("keydown", keyboard);
  });

  function choiceBlocked(choice: TreatmentChoice) {
    return choice === "split" ? cases.length !== 1 : choice === "claim" ? cases.some(entry => !entry.claimable || entry.cess_issue) : choice === "later" && cases.some(entry => entry.cess_issue);
  }
  function open(button: HTMLButtonElement) {
    opener.current = button;
    openingCases.current = structuredClone(cases);
    setValues(cases.length === 1 ? structuredClone(cases[0].values) : blankValues());
    mutation.reset(); setSaved(""); setDialogOpen(true);
  }
  type ReviewWrite = { controller: AbortController; itemId: string; case_ids: number[]; basis: Record<string, string> } & ({ kind: "treatment"; values: import("@/lib/generated/workspace").components["schemas"]["TreatmentInput"]; andNext: boolean } | { kind: "document" });
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: (write: ReviewWrite) => write.kind === "treatment"
      ? savePurchaseTreatment(String(data.client.id), data.period, write.itemId, data.filter, data.q, { case_ids: write.case_ids, basis: write.basis, values: write.values }, write.controller.signal)
      : recordPurchaseDocument(String(data.client.id), data.period, write.itemId, data.filter, data.q, { case_ids: write.case_ids, basis: write.basis }, write.controller.signal),
    onSuccess: async (fresh, write) => {
      if (write.controller.signal.aborted) return;
      await cache.cancelQueries({ queryKey });
      if (write.controller.signal.aborted) return;
      void cache.invalidateQueries({ queryKey: ["purchase-review", String(data.client.id), data.period], refetchType: "none" });
      cache.setQueryData(queryKey, fresh);
      void cache.invalidateQueries({ queryKey: ["purchases"], refetchType: "none" });
      if (write.kind === "document") {
        setSaved("Invoice possession recorded. Review the available ITC choices.");
        return;
      }
      setDialogOpen(false); setSaved("ITC treatment saved.");
      if (write.andNext) {
        const target = fresh.queue.find(row => row.id === next?.id) ?? fresh.queue.find(row => row.id !== write.itemId);
        if (target) navigate(`${base}/review/${encodeURIComponent(target.id)}?${params}`);
        else setSaved("ITC treatment saved. No more items in this queue.");
      }
    },
    onError: async (failure, write) => {
      if (write.controller.signal.aborted) return;
      if (failure instanceof PurchaseReviewError && [403, 404, 409].includes(failure.status)) {
        if (write.kind === "treatment") setDialogOpen(false);
        await refresh();
      }
    },
    onSettled: (_result, _failure, write) => {
      if (operation.current === write.controller) operation.current = null;
    },
  });
  const busy = mutation.isPending;
  const canEdit = !blocked && !busy && !refreshing;
  const error = mutation.error?.message ?? null;

  function save(andNext: boolean) {
    if (!item || !canEdit || !values.choice || choiceBlocked(values.choice) || operation.current) return;
    const controller = new AbortController(); operation.current = controller; setSaved("");
    mutation.mutate({ kind: "treatment", controller, itemId: item.id, case_ids: openingCases.current.map(entry => entry.id), basis: Object.fromEntries(openingCases.current.map(entry => [entry.id, entry.basis])), values: { ...structuredClone(values), choice: values.choice as TreatmentChoice }, andNext });
  }

  function recordDocument(entry: PurchaseReviewData["cases"][number]) {
    if (!item || busy || refreshing || !data.can_edit || !entry.can_record_document || operation.current) return;
    const controller = new AbortController(); operation.current = controller; setSaved("");
    mutation.mutate({ kind: "document", controller, itemId: item.id, case_ids: [entry.id], basis: { [entry.id]: entry.basis } });
  }

  return <main className="min-h-screen bg-neutral-50/70">
    <header className="flex flex-wrap items-center justify-between gap-4 border-b bg-white px-6 py-4"><Link to={base} onClick={event => { if (busy) event.preventDefault(); }} className="inline-flex items-center gap-2 text-sm"><ArrowLeft className="size-4" />Back to purchases</Link><div className="text-sm text-muted-foreground">{data.client.name} · {data.month_label}</div><div className="flex items-center gap-2"><ShortcutHelpButton /><span className="text-sm text-muted-foreground">{position >= 0 ? `${position + 1} of ${data.queue.length}` : `${data.queue.length} items`}</span><Button variant="ghost" size="icon-sm" aria-label="Previous purchase" disabled={!previous || busy || dialogOpen} onClick={() => go(previous?.id)}><ChevronLeft /></Button><Button variant="ghost" size="icon-sm" aria-label="Next purchase" disabled={!next || busy || dialogOpen} onClick={() => go(next?.id)}><ChevronRight /></Button></div></header>
    <div className="mx-auto grid max-w-screen-2xl gap-6 p-6 lg:grid-cols-[240px_minmax(0,1fr)]">
      <aside aria-label="Purchase queue" className="space-y-4"><h2 className="font-semibold">Review queue</h2><NativeSelect aria-label="Review filter" value={data.filter} disabled={busy || dialogOpen} onChange={event => { const nextParams = new URLSearchParams(params); nextParams.set("filter", event.target.value); navigate(`${base}/review?${nextParams}`); }}>{[{ id: "needs_review", label: "Needs review" }, { id: "all", label: "All items" }, { id: "treatment", label: "ITC treatment" }, { id: "matched", label: "Matched" }, { id: "mismatch", label: "Mismatch" }, { id: "books_only", label: "Books only" }, { id: "2b_only", label: "GSTR-2B only" }, { id: "possible", label: "Possible matches" }, { id: "itc", label: "ITC checks" }, { id: "carried", label: "Carried entries" }, { id: "register", label: "Purchase books" }, { id: "gstr2b", label: "GSTR-2B" }].map(filter => <option key={filter.id} value={filter.id}>{filter.label}</option>)}</NativeSelect><form className="flex gap-2" onSubmit={event => { event.preventDefault(); const nextParams = new URLSearchParams(params); const q = String(new FormData(event.currentTarget).get("q") ?? "").slice(0, 200); q ? nextParams.set("q", q) : nextParams.delete("q"); navigate(`${base}/review?${nextParams}`); }}><Input name="q" defaultValue={data.q} data-shortcut-search aria-label="Search review queue" maxLength={200} disabled={busy || dialogOpen} /><Button type="submit" variant="outline" disabled={busy || dialogOpen}>Search</Button></form><nav className="max-h-96 overflow-auto rounded-lg border bg-white lg:max-h-[65vh]">{data.queue.map(row => <button key={row.id} type="button" disabled={busy || dialogOpen} aria-current={row.id === item?.id ? "page" : undefined} onClick={() => go(row.id)} className={`block w-full border-b px-3 py-3 text-left text-sm last:border-0 hover:bg-muted focus-visible:outline-2 focus-visible:outline-ring ${row.id === item?.id ? "bg-muted" : ""}`}><span className="block font-medium">{row.number}</span><span className="mt-1 block truncate text-muted-foreground">{row.vendor}</span><span className="mt-1 block text-xs text-muted-foreground">{row.status}</span></button>)}</nav><p className="text-xs text-muted-foreground">Alt + ← / → moves between purchases.</p></aside>
      <div className="min-w-0 space-y-5">{error && <p role="alert" className="rounded-lg border border-destructive/30 bg-white p-4 text-sm text-destructive">{error}</p>}{saved && <p role="status" className="rounded-lg border bg-white p-4 text-sm">{saved}</p>}{data.lock_reason && <p className="text-sm text-muted-foreground">{data.lock_reason}</p>}
        {!item ? <section className="rounded-lg border bg-white p-8"><h1 className="text-xl font-semibold">No purchases in this queue</h1><p className="mt-2 text-sm text-muted-foreground">Choose another filter or change your search.</p></section> : <><header className="flex flex-wrap items-start justify-between gap-4"><div><h1 className="text-2xl font-semibold tracking-tight">Purchase {item.number}</h1><p className="mt-1 text-sm text-muted-foreground">{item.vendor}</p></div><Badge variant="outline">{item.status}</Badge></header>{item.reason && <p className="text-sm text-muted-foreground">{item.reason}</p>}
          {item.comparisons.map((comparison, index) => <section key={comparison.id} aria-label={`Source comparison ${index + 1}`} className="overflow-hidden rounded-lg border bg-white"><Table><TableHeader><TableRow><TableHead>Invoice detail</TableHead><TableHead>Purchase books</TableHead><TableHead>GSTR-2B</TableHead></TableRow></TableHeader><TableBody>{comparison.facts.map(fact => <TableRow key={fact.label} className={fact.different ? "bg-muted/50" : ""}><TableCell className="font-medium">{fact.label}{fact.different && <span className="ml-2 text-xs font-normal text-muted-foreground">Differs</span>}</TableCell><TableCell className="whitespace-normal">{fact.books}</TableCell><TableCell className="whitespace-normal">{fact.portal}</TableCell></TableRow>)}</TableBody></Table>{comparison.original_url && <a href={comparison.original_url} target="_blank" rel="noreferrer" className="m-4 inline-flex items-center gap-2 text-sm underline">Open original source <ExternalLink className="size-3" /><span className="sr-only"> (new tab)</span></a>}</section>)}
          <section aria-labelledby="itc-treatment-title" className="space-y-4 rounded-lg border bg-white p-5"><div className="flex flex-wrap items-center justify-between gap-3"><h2 id="itc-treatment-title" className="font-semibold">ITC treatment</h2><Button disabled={!canEdit} onClick={event => open(event.currentTarget)}>Set ITC treatment</Button></div>{item.pairing_pending && <p className="text-sm">Resolve the uncertain pairing before setting ITC treatment.</p>}{cases.length === 0 && <p className="text-sm text-muted-foreground">No ITC treatment is available for this item.</p>}{cases.map(entry => <div key={entry.id} className="space-y-1 text-sm"><p className="font-medium">{entry.number} · {choices.find(choice => choice.id === entry.values.choice)?.label ?? "No treatment recorded"}</p>{entry.values.later_reason && <p className="text-muted-foreground">{data.reasons.later.find(reason => reason.id === entry.values.later_reason)?.label ?? entry.values.later_reason}</p>}{entry.values.exclude_reason && <p className="text-muted-foreground">{data.reasons.exclude.find(reason => reason.id === entry.values.exclude_reason)?.label ?? entry.values.exclude_reason}</p>}{entry.values.choice === "split" && <dl className="space-y-1">{entry.heads.map(head => <div key={head.id}><dt className="inline font-medium">{head.label}: </dt><dd className="inline">Claim ₹{entry.values.split.claim[head.id]} · Later ₹{entry.values.split.later[head.id]} · Exclude ₹{entry.values.split.exclude[head.id]}</dd></div>)}</dl>}{entry.values.note && <p className="text-muted-foreground">{entry.values.note}</p>}{entry.unavailable_reason && <p className="text-muted-foreground">{entry.unavailable_reason}</p>}{entry.claim_block_reason && <p className="text-muted-foreground">{entry.claim_block_reason}</p>}{entry.cess_issue && <p className="text-muted-foreground">{entry.cess_issue}</p>}{entry.can_record_document && <Button variant="outline" size="sm" disabled={!data.can_edit || busy || refreshing} onClick={() => void recordDocument(entry)}>I have this invoice</Button>}</div>)}<a href={item.legacy_url} className="inline-block text-sm underline underline-offset-4">Open source corrections and pairing</a></section>
        </>}
      </div>
    </div>
    <Dialog open={dialogOpen} onOpenChange={open => { if (!busy) setDialogOpen(open); }}><DialogContent finalFocus={opener} className="max-h-[90vh] overflow-y-auto sm:max-w-xl"><DialogHeader><DialogTitle>Set ITC treatment</DialogTitle><DialogDescription>{item?.number} · {cases.length === 1 ? cases[0].vendor : `${cases.length} invoices`}. Only saved decisions change the working.</DialogDescription></DialogHeader><form className="space-y-5" onKeyDown={event => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey && !event.repeat && !event.nativeEvent.isComposing) { event.preventDefault(); void save(true); } }} onSubmit={event => { event.preventDefault(); void save(false); }}>{error && <p role="alert" className="text-sm text-destructive">{error}</p>}<div className="flex flex-wrap gap-x-5 gap-y-2 text-sm">{cases.length === 1 && cases[0].heads.map(head => <p key={head.id}><span className="text-muted-foreground">{head.label}</span> <span className="font-medium tabular-nums">{head.amount}</span></p>)}</div><RadioGroup aria-label="ITC treatment" value={values.choice ?? ""} disabled={busy} onValueChange={value => setValues(current => ({ ...current, choice: value as TreatmentChoice }))} className="grid-cols-2 gap-3">{choices.map(choice => <label key={choice.id} className="flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-3 text-sm has-data-checked:border-primary has-data-checked:bg-muted/50 has-data-disabled:cursor-not-allowed has-data-disabled:opacity-50"><RadioGroupItem value={choice.id} disabled={choiceBlocked(choice.id)} /><span>{choice.label}</span></label>)}</RadioGroup>{[...new Set(cases.flatMap(entry => [entry.claim_block_reason, entry.cess_issue]).filter(Boolean))].map(reason => <p key={reason} className="text-sm text-muted-foreground">{reason}</p>)}{cases.length > 1 && <p className="text-sm text-muted-foreground">This decision applies to all {cases.length} invoices. Split amounts requires one invoice.</p>}
      {(["later", "exclude"] as const).filter(kind => values.choice === kind || values.choice === "split").map(kind => <label key={kind} className="block space-y-2 text-sm"><span>{kind === "later" ? "Why claim later?" : "Why exclude?"}</span><NativeSelect value={values[`${kind}_reason`]} disabled={busy} onChange={event => setValues(current => ({ ...current, [`${kind}_reason`]: event.target.value }))}><option value="">Choose a reason</option>{data.reasons[kind].map(reason => <option key={reason.id} value={reason.id}>{reason.label}</option>)}</NativeSelect></label>)}
      {values.choice === "split" && cases.length === 1 && <div className="space-y-4"><p className="text-sm text-muted-foreground">Enter rupee amounts. Each tax head must add up to its available amount.</p>{cases[0].heads.map(head => <fieldset key={head.id} className="space-y-2"><legend className="text-sm font-medium">{head.label} available: {head.amount}</legend><div className="grid grid-cols-3 gap-2">{(["claim", "later", "exclude"] as const).map(part => <label key={part} className="space-y-1 text-sm"><span>{part === "claim" ? "Claim" : part === "later" ? "Later" : "Exclude"}</span><Input aria-label={`${head.label} ${part}`} inputMode="decimal" disabled={busy || (head.id === "cess" && part !== "exclude") || (part === "claim" && !cases[0].can_claim_split)} value={values.split[part][head.id]} onChange={event => setValues(current => ({ ...current, split: { ...current.split, [part]: { ...current.split[part], [head.id]: event.target.value } } }))} /></label>)}</div></fieldset>)}</div>}
      {values.choice && values.choice !== "claim" && <label className="block space-y-2 text-sm"><span>Note</span><Textarea rows={3} value={values.note} maxLength={1000} disabled={busy} onChange={event => setValues(current => ({ ...current, note: event.target.value }))} /></label>}<div className="flex flex-wrap justify-end gap-2"><Button type="button" variant="ghost" disabled={busy} onClick={() => setDialogOpen(false)}>Cancel</Button><Button type="submit" variant="outline" disabled={!canEdit || !values.choice || choiceBlocked(values.choice)}>{busy ? "Saving…" : "Save"}</Button><Button type="button" disabled={!canEdit || !values.choice || choiceBlocked(values.choice)} onClick={() => void save(true)} title="Ctrl + Enter">Save and next</Button></div></form></DialogContent></Dialog>
  </main>;
}
