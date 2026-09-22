import { createContext, useContext, useState } from "react";
import { Link, useLocation, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, ArrowRight, ChevronDown, ChevronLeft, ChevronRight } from "lucide-react";
import { Gstr2bSource } from "@/components/gstr2b-source";
import { Shell } from "@/components/workspace-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { Dialog, DialogTrigger, DialogContent, DialogHeader, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { Table, TableHeader, TableHead, TableBody, TableRow, TableCell } from "@/components/ui/table";
import { ApiError } from "@/lib/sales-api";
import { fetchPurchases, type PurchasesWorkspace } from "@/lib/purchases-api";

const Workspace = createContext<PurchasesWorkspace | null>(null);
export function usePurchases() {
  const data = useContext(Workspace);
  if (!data) throw new Error("Purchases workspace is missing");
  return data;
}
const basePath = (data: PurchasesWorkspace) => `/gst/${data.client.id}/${data.period}/purchases`;

export function LivePurchasesLayout() {
  const { clientId = "", period = "" } = useParams();
  const [params] = useSearchParams();
  const { pathname } = useLocation();
  const register = pathname.endsWith("/register");
  const filter = register && params.get("source") === "gstr2b" ? "gstr2b" : "register";
  const q = register ? (params.get("q") ?? "").slice(0, 200) : "";
  const query = useQuery({
    queryKey: ["purchases", clientId, period, filter, q],
    queryFn: ({ signal }) => fetchPurchases(clientId, period, filter, q, signal),
    staleTime: 0,
    placeholderData: (previous, previousQuery) => previousQuery?.queryKey[1] === clientId && previousQuery.queryKey[2] === period && previousQuery.queryKey[3] === filter ? previous : undefined,
    retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 1,
    refetchInterval: query => query.state.data?.processing || query.state.data?.inputs.portal.fetching ? 5000 : false,
  });
  if (query.isPending) return <main className="px-6 py-16" aria-busy="true"><p role="status">Loading purchases…</p></main>;
  if (query.isError) return <main className="mx-auto max-w-xl px-6 py-24"><h1 className="text-2xl font-semibold">Purchases unavailable</h1><p role="alert" className="my-4 text-muted-foreground">{query.error.message}</p>{query.error instanceof ApiError && query.error.status === 401 ? <a href="/users/log_in" className="underline">Sign in</a> : <Button onClick={() => query.refetch()}>Try again</Button>}<Link to="/clients" className="ml-5 text-sm underline">Back to clients</Link></main>;
  const data = query.data;
  return <Workspace.Provider value={data}><Shell live={{ ...data, base: `/gst/${data.client.id}/${data.period}/sales`, purchases: basePath(data) }} /></Workspace.Provider>;
}

function LegacyAction({ href, children, disabled = false }: { href: string; children: React.ReactNode; disabled?: boolean }) {
  return disabled ? <Button variant="outline" size="sm" disabled>{children}</Button> : <Button variant="outline" size="sm" nativeButton={false} role="link" render={<a href={href} />}>{children}</Button>;
}

function ReviewAction({ href, children }: { href: string; children: React.ReactNode }) {
  return <Button variant="outline" size="sm" nativeButton={false} role="link" render={<Link to={href} />}>{children}</Button>;
}

function PeriodControl() {
  const data = usePurchases();
  const navigate = useNavigate();
  const { pathname, search } = useLocation();
  const [open, setOpen] = useState(false);
  const current = new Date().toISOString().slice(0, 7);
  const go = (period: string) => navigate(pathname.replace(`/${data.period}/`, `/${period}/`) + search);
  const shift = (delta: number) => {
    const date = new Date(`${data.period}-01T12:00:00Z`);
    date.setUTCMonth(date.getUTCMonth() + delta);
    go(date.toISOString().slice(0, 7));
  };
  return <div className="flex items-center gap-1"><Dialog open={open} onOpenChange={setOpen}><DialogTrigger render={<Button variant="ghost" size="sm" />} aria-label="Choose month">{data.month_label}<ChevronDown /></DialogTrigger><DialogContent><DialogHeader><DialogTitle>Choose working month</DialogTitle><DialogDescription>Open purchases for another month.</DialogDescription></DialogHeader><Input type="month" aria-label="Working month" min="2017-07" max={current} value={data.period} onChange={event => { const value = event.target.value; if (/^\d{4}-\d{2}$/.test(value) && value >= "2017-07" && value <= current) { go(value); setOpen(false); } }} /></DialogContent></Dialog><Button variant="ghost" size="icon-sm" aria-label="Previous month" disabled={data.period <= "2017-07"} onClick={() => shift(-1)}><ChevronLeft /></Button><Button variant="ghost" size="icon-sm" aria-label="Next month" disabled={data.period >= current} onClick={() => shift(1)}><ChevronRight /></Button></div>;
}

export function LivePurchasesSummary() {
  const data = usePurchases();
  const { overview, inputs } = data;
  return <div className="space-y-8">
    <header className="flex flex-wrap items-start justify-between gap-4"><div><PeriodControl /><h1 className="text-3xl font-semibold tracking-tight">Purchases & ITC</h1></div>{data.signed_off && <Badge variant="outline">Signed off</Badge>}</header>
    {data.lock_reason && <p className="text-sm text-muted-foreground">{data.lock_reason}</p>}
    {data.notice && <p role="status" className="rounded-lg border bg-white p-4 text-sm">{data.notice}</p>}
    <section aria-label="Sources" className="grid gap-4 sm:grid-cols-2">
      {([{ key: "purchases", title: "Purchase register", input: inputs.books }, { key: "gstr2b", title: "GSTR-2B", input: inputs.portal }] as const).map(({ key, title, input }) => <div key={key} className="rounded-lg border bg-white p-5"><div className="flex items-center justify-between gap-3"><h2 className="font-medium">{title}</h2><Link to={`${basePath(data)}/register?source=${key}`} className="text-sm underline underline-offset-4">View register</Link></div><p className="mt-4 text-2xl font-semibold tabular-nums">{input.present ? input.tax : "Not imported"}{input.present && <span className="ml-2 text-sm font-normal text-muted-foreground">GST</span>}</p><p className="mt-1 text-sm text-muted-foreground">{input.present ? `${input.count} source ${input.count === 1 ? "document" : "documents"}` : "No source documents yet"}</p><div className="mt-5 flex flex-wrap gap-2">{key === "purchases" ? <><LegacyAction href={data.links.import_excel} disabled={!data.can_edit}>Import Excel</LegacyAction><LegacyAction href={data.links.uploads}>Uploads</LegacyAction></> : <Gstr2bSource key={`${data.client.id}:${data.period}`} client={data.client.id} period={data.period} />}</div></div>)}
    </section>
    <div className="grid items-start gap-6 xl:grid-cols-[minmax(0,1fr)_320px]"><section aria-labelledby="reconciliation-heading" className="overflow-hidden rounded-lg border bg-white"><div className="flex flex-wrap items-start justify-between gap-3 p-5"><div><h2 id="reconciliation-heading" className="font-semibold">Reconciliation</h2><p className="mt-1 text-sm text-muted-foreground">{overview.comparison_available ? overview.remaining === 0 ? "No reconciliation items await review." : `${overview.remaining} ${overview.remaining === 1 ? "item needs" : "items need"} review.` : "Add both sources to compare purchase books with GSTR-2B."}</p></div><ReviewAction href={data.links.review}>Open reconciliation <ArrowRight /></ReviewAction></div>{overview.comparison_available && <Table><TableHeader><TableRow><TableHead>Result</TableHead><TableHead className="text-right">Items</TableHead><TableHead className="text-right">Books tax</TableHead><TableHead className="text-right">GSTR-2B tax</TableHead></TableRow></TableHeader><TableBody>{overview.buckets.map(bucket => <TableRow key={bucket.id}><TableCell><Link to={`${basePath(data)}/review?${new URLSearchParams({ filter: bucket.id })}`} className="underline underline-offset-4">{bucket.label}</Link></TableCell><TableCell className="text-right tabular-nums">{bucket.count}</TableCell><TableCell className="text-right tabular-nums">{bucket.books_tax}</TableCell><TableCell className="text-right tabular-nums">{bucket.portal_tax}</TableCell></TableRow>)}</TableBody></Table>}</section>
    <aside className="space-y-5"><section aria-labelledby="itc-heading" className="rounded-lg border bg-white p-5"><div className="flex flex-wrap items-start justify-between gap-3"><div><h2 id="itc-heading" className="font-semibold">ITC treatment</h2><p className="mt-1 text-sm text-muted-foreground">{overview.itc.recorded ? `${overview.itc.pending} tax awaiting treatment.` : "No ITC treatment recorded yet."} {!inputs.books.present && inputs.portal.present && "Review GSTR-2B to record ITC decisions."}</p></div><ReviewAction href={data.links.treatment}>Open ITC treatment <ArrowRight /></ReviewAction></div>{overview.itc.recorded && <dl className="mt-5 grid gap-3">{[{ label: "Claim", value: overview.itc.claim }, { label: "Later", value: overview.itc.later }, { label: "Excluded", value: overview.itc.excluded }].map(item => <div key={item.label} className="flex items-baseline justify-between gap-3"><dt className="text-sm text-muted-foreground">{item.label}</dt><dd className="text-base font-semibold tabular-nums">{item.value}</dd></div>)}</dl>}{overview.itc.carried_count > 0 && <p className="mt-5 text-sm"><Link to={data.links.carried} className="underline underline-offset-4">{overview.itc.carried_count} carried {overview.itc.carried_count === 1 ? "entry" : "entries"}</Link>{overview.itc.stale_count > 0 && ` · ${overview.itc.stale_count} need a fresh check`}</p>}</section>
    <section aria-labelledby="working-heading" className="flex flex-wrap items-center justify-between gap-4 rounded-lg border bg-white p-5"><div><h2 id="working-heading" className="font-semibold">Purchase working</h2><p className="mt-1 text-sm text-muted-foreground">{data.working.status}</p>{data.working.reason && <p className="mt-1 text-sm text-muted-foreground">{data.working.reason}</p>}</div><LegacyAction href={data.working.url} disabled={!data.working.enabled}>Download working</LegacyAction></section></aside></div>
  </div>;
}

export function LivePurchasesRegister() {
  const data = usePurchases();
  const [params, setParams] = useSearchParams();
  const source = params.get("source") === "gstr2b" ? "gstr2b" : "purchases";
  const q = (params.get("q") ?? "").slice(0, 200);
  return <div className="space-y-6"><Link to={basePath(data)} className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"><ArrowLeft className="size-4" />Back to purchases</Link><header><PeriodControl /><h1 className="text-3xl font-semibold tracking-tight">{source === "gstr2b" ? "GSTR-2B register" : "Purchase register"}</h1><p className="mt-2 text-sm text-muted-foreground">Original source entries, including entries already linked during reconciliation.</p></header><div className="flex flex-wrap items-center justify-between gap-4"><nav aria-label="Register source" className="flex gap-2">{[{ id: "purchases", label: "Purchase books" }, { id: "gstr2b", label: "GSTR-2B" }].map(item => <Button key={item.id} variant={source === item.id ? "secondary" : "ghost"} nativeButton={false} role="link" render={<Link aria-current={source === item.id ? "page" : undefined} to={`${basePath(data)}/register?${new URLSearchParams({ source: item.id, ...(q ? { q } : {}) })}`} />}>{item.label}</Button>)}</nav><form className="flex w-full gap-2 sm:w-auto" onSubmit={event => { event.preventDefault(); const value = String(new FormData(event.currentTarget).get("q") ?? "").slice(0, 200); const next = new URLSearchParams(params); next.set("source", source); value ? next.set("q", value) : next.delete("q"); setParams(next, { replace: true }); }}><Input key={q} name="q" data-shortcut-search aria-label="Search source entries" placeholder="Search vendor, invoice or GSTIN" maxLength={200} defaultValue={q} className="w-full sm:w-72" /><Button type="submit" variant="outline">Search</Button></form></div><div className="overflow-hidden rounded-lg border bg-white"><Table><TableHeader><TableRow><TableHead>Invoice</TableHead><TableHead>Date</TableHead><TableHead>Vendor</TableHead><TableHead>Type</TableHead><TableHead className="text-right">GST</TableHead><TableHead>Status</TableHead><TableHead><span className="sr-only">Review</span></TableHead></TableRow></TableHeader><TableBody>{(data.q === q ? data.rows : []).map(row => <TableRow key={row.id}><TableCell className="font-medium">{row.number}</TableCell><TableCell className="whitespace-nowrap">{row.date ?? "—"}</TableCell><TableCell><div>{row.vendor}</div><div className="mt-1 text-xs text-muted-foreground">{row.gstin ?? "GSTIN not provided"}</div></TableCell><TableCell>{row.document_type}</TableCell><TableCell className="whitespace-nowrap text-right tabular-nums">{row.tax}</TableCell><TableCell><span>{row.status}</span>{row.reason && <p className="mt-1 max-w-64 text-xs text-muted-foreground whitespace-normal">{row.reason}</p>}</TableCell><TableCell>{row.review_url && <Link to={row.review_url} className="text-sm underline underline-offset-4" aria-label={`Review ${row.number}`}>Review</Link>}</TableCell></TableRow>)}</TableBody></Table>{data.q !== q && <p role="status" className="p-10 text-center text-sm text-muted-foreground">Searching source entries…</p>}{data.q === q && data.rows.length === 0 && <div className="p-10 text-center"><p className="text-sm text-muted-foreground">{q ? "No source entries match this search." : "No source entries for this month."}</p>{q && <Button variant="ghost" className="mt-3" onClick={() => { const next = new URLSearchParams(params); next.delete("q"); setParams(next, { replace: true }); }}>Clear search</Button>}</div>}</div><p className="text-xs text-muted-foreground">{data.rows.length} source entries shown. Amounts and reconciliation status come from the recorded sources.</p></div>;
}
