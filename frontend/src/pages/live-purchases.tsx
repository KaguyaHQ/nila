import { PurchaseWorklist } from "@/components/purchase-worklist";
import { createContext, useContext } from "react";
import { Link, useLocation, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { ArrowLeft, ArrowRight, ChevronLeft, ChevronRight } from "lucide-react";
import { PurchaseRegisterTable } from "@/components/purchase-register-table";
import { Gstr2bSource } from "@/components/gstr2b-source";
import { Shell } from "@/components/workspace-shell";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { MonthPicker } from "@/components/month-picker";
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
    placeholderData: (previous, previousQuery) =>
      previousQuery?.queryKey[1] === clientId &&
      previousQuery.queryKey[2] === period &&
      previousQuery.queryKey[3] === filter
        ? previous
        : undefined,
    retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 1,
    refetchInterval: (query) =>
      query.state.data?.processing || query.state.data?.inputs.portal.fetching ? 5000 : false,
  });
  if (query.isPending)
    return (
      <main className="px-6 py-16" aria-busy="true">
        <p role="status">Loading purchases…</p>
      </main>
    );
  if (query.isError)
    return (
      <main className="mx-auto max-w-xl px-6 py-24">
        <h1 className="text-2xl font-semibold">Purchases unavailable</h1>
        <p role="alert" className="my-4 text-muted-foreground">
          {query.error.message}
        </p>
        {query.error instanceof ApiError && query.error.status === 401 ? (
          <a href="/users/log_in" className="underline">
            Sign in
          </a>
        ) : (
          <Button onClick={() => query.refetch()}>Try again</Button>
        )}
        <Link to="/clients" className="ml-5 text-sm underline">
          Back to clients
        </Link>
      </main>
    );
  const data = query.data;
  return (
    <Workspace.Provider value={data}>
      <Shell
        live={{
          ...data,
          base: `/gst/${data.client.id}/${data.period}/sales`,
          purchases: basePath(data),
        }}
      />
    </Workspace.Provider>
  );
}

function LegacyAction({
  href,
  children,
  disabled = false,
}: {
  href: string;
  children: React.ReactNode;
  disabled?: boolean;
}) {
  return disabled ? (
    <Button variant="outline" size="sm" disabled>
      {children}
    </Button>
  ) : (
    <Button variant="outline" size="sm" nativeButton={false} role="link" render={<a href={href} />}>
      {children}
    </Button>
  );
}

function PeriodControl() {
  const data = usePurchases();
  const navigate = useNavigate();
  const { pathname, search } = useLocation();
  const current = new Date().toISOString().slice(0, 7);
  const go = (period: string) =>
    navigate(pathname.replace(`/${data.period}/`, `/${period}/`) + search);
  const shift = (delta: number) => {
    const date = new Date(`${data.period}-01T12:00:00Z`);
    date.setUTCMonth(date.getUTCMonth() + delta);
    go(date.toISOString().slice(0, 7));
  };
  return (
    <div className="flex items-center gap-1">
      <MonthPicker period={data.period} label={data.month_label} max={current} onSelect={go} />
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label="Previous month"
        disabled={data.period <= "2017-07"}
        onClick={() => shift(-1)}
      >
        <ChevronLeft />
      </Button>
      <Button
        variant="ghost"
        size="icon-sm"
        aria-label="Next month"
        disabled={data.period >= current}
        onClick={() => shift(1)}
      >
        <ChevronRight />
      </Button>
    </div>
  );
}

export function LivePurchasesSummary() {
  const data = usePurchases();
  const { overview, inputs } = data;
  const draft = !data.signed_off && !overview.complete;
  const canReview =
    inputs.books.count > 0 || inputs.portal.count > 0 || overview.itc.carried_count > 0;
  return (
    <div className="space-y-8">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <PeriodControl />
          <h1 className="text-3xl font-semibold tracking-tight">Purchases & ITC</h1>
        </div>
        <div className="flex items-center gap-3">
          {data.signed_off && <Badge variant="outline">Signed off</Badge>}
          {canReview && (
            <Button nativeButton={false} role="link" render={<Link to={data.links.treatment} />}>
              Review purchases <ArrowRight />
            </Button>
          )}
        </div>
      </header>
      {data.lock_reason && <p className="text-sm text-muted-foreground">{data.lock_reason}</p>}
      {(data.processing || inputs.portal.needs_import) && data.notice && (
        <p role="status" className="text-sm text-muted-foreground">
          {data.notice}
        </p>
      )}
      <div className="flex flex-wrap items-center gap-x-8 gap-y-2 text-sm">
        <span>
          <strong>{overview.itc.claim}</strong> claim this month
        </span>
        <span>
          <strong>{overview.itc.later}</strong> claim later
        </span>
        <span>
          <strong>{overview.itc.excluded}</strong> do not claim
        </span>
        <span className="text-muted-foreground">
          {overview.itc.pending} tax awaiting treatment.
        </span>
      </div>
      <PurchaseWorklist
        key={`${data.client.id}:${data.period}`}
        client={data.client.id}
        period={data.period}
        importAction={
          <LegacyAction href={data.links.import_excel} disabled={!data.can_edit}>
            Import purchase Excel
          </LegacyAction>
        }
        portalAvailable={inputs.portal.present}
      />
      <section aria-label="Sources" className="grid gap-4 sm:grid-cols-2">
        {(
          [
            { key: "purchases", title: "Purchase register", input: inputs.books },
            { key: "gstr2b", title: "GSTR-2B", input: inputs.portal },
          ] as const
        ).map(({ key, title, input }) => (
          <div key={key} className="rounded-lg border bg-white p-5">
            <div className="flex items-center justify-between gap-3">
              <h2 className="font-medium">{title}</h2>
              {input.present && (
                <Link
                  to={`${basePath(data)}/register?source=${key}`}
                  className="text-sm underline underline-offset-4"
                >
                  View register
                </Link>
              )}
            </div>
            <p className="mt-3 text-lg font-semibold tabular-nums">
              {input.present ? input.tax : "Not imported"}
              {input.present && (
                <span className="ml-2 text-sm font-normal text-muted-foreground">GST</span>
              )}
            </p>
            <p className="mt-1 text-sm text-muted-foreground">
              {input.present
                ? `${input.count} source ${input.count === 1 ? "document" : "documents"}`
                : "No source documents yet"}
            </p>
            <div className="mt-3 flex flex-wrap gap-2">
              {key === "purchases" ? (
                <>
                  <LegacyAction href={data.links.import_excel} disabled={!data.can_edit}>
                    Import Excel
                  </LegacyAction>
                  <LegacyAction href={data.links.uploads}>Uploads</LegacyAction>
                </>
              ) : (
                <Gstr2bSource
                  key={`${data.client.id}:${data.period}`}
                  client={data.client.id}
                  period={data.period}
                />
              )}
            </div>
          </div>
        ))}
      </section>
      <section
        aria-labelledby="working-heading"
        className="flex flex-wrap items-center justify-between gap-4 rounded-lg border bg-white p-5"
      >
        <div>
          <h2 id="working-heading" className="font-semibold">
            Purchase working
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">{data.working.status}</p>
          {data.working.reason && (
            <p className="mt-1 text-sm text-muted-foreground">{data.working.reason}</p>
          )}
          {draft && !data.working.reason && !overview.comparison_available && (
            <p className="mt-1 text-sm text-muted-foreground">
              {!inputs.books.present ? "Purchase register not imported." : "GSTR-2B not imported."}{" "}
              Reconciliation is pending.
            </p>
          )}
        </div>
        <LegacyAction href={data.working.url} disabled={!data.working.enabled}>
          {draft ? "Download draft working" : "Download working"}
        </LegacyAction>
      </section>
    </div>
  );
}

const emptyRegisterRows: PurchasesWorkspace["rows"] = [];

export function LivePurchasesRegister() {
  const data = usePurchases();
  const [params, setParams] = useSearchParams();
  const source = params.get("source") === "gstr2b" ? "gstr2b" : "purchases";
  const q = (params.get("q") ?? "").slice(0, 200);
  return (
    <div className="space-y-6">
      <Link
        to={basePath(data)}
        className="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="size-4" />
        Back to purchases
      </Link>
      <header>
        <PeriodControl />
        <h1 className="text-3xl font-semibold tracking-tight">
          {source === "gstr2b" ? "GSTR-2B register" : "Purchase register"}
        </h1>
        <p className="mt-2 text-sm text-muted-foreground">
          {data.overview.comparison_available
            ? "Original records with their reconciliation status."
            : "Import both sources to compare purchase books with GSTR-2B."}
        </p>
      </header>
      <div className="flex flex-wrap items-center justify-between gap-4">
        <nav aria-label="Register source" className="flex gap-2">
          {[
            { id: "purchases", label: "Purchase books" },
            { id: "gstr2b", label: "GSTR-2B" },
          ].map((item) => (
            <Button
              key={item.id}
              variant={source === item.id ? "secondary" : "ghost"}
              nativeButton={false}
              role="link"
              render={
                <Link
                  aria-current={source === item.id ? "page" : undefined}
                  to={`${basePath(data)}/register?${new URLSearchParams({ source: item.id, ...(q ? { q } : {}) })}`}
                />
              }
            >
              {item.label}
            </Button>
          ))}
        </nav>
        <form
          className="flex w-full gap-2 sm:w-auto"
          onSubmit={(event) => {
            event.preventDefault();
            const value = String(new FormData(event.currentTarget).get("q") ?? "").slice(0, 200);
            const next = new URLSearchParams(params);
            next.set("source", source);
            value ? next.set("q", value) : next.delete("q");
            setParams(next, { replace: true });
          }}
        >
          <Input
            key={q}
            name="q"
            data-shortcut-search
            aria-label="Search source entries"
            placeholder="Search vendor, invoice or GSTIN"
            maxLength={200}
            defaultValue={q}
            className="w-full sm:w-72"
          />
          <Button type="submit" variant="outline">
            Search
          </Button>
        </form>
      </div>
      <div className="overflow-hidden rounded-lg border bg-white">
        <PurchaseRegisterTable
          rows={data.q === q ? data.rows : emptyRegisterRows}
          comparisonAvailable={data.overview.comparison_available}
        />
        {data.q !== q && (
          <p role="status" className="p-10 text-center text-sm text-muted-foreground">
            Searching source entries…
          </p>
        )}
        {data.q === q && data.rows.length === 0 && (
          <div className="p-10 text-center">
            <p className="text-sm text-muted-foreground">
              {q ? "No source entries match this search." : "No source entries for this month."}
            </p>
            {q && (
              <Button
                variant="ghost"
                className="mt-3"
                onClick={() => {
                  const next = new URLSearchParams(params);
                  next.delete("q");
                  setParams(next, { replace: true });
                }}
              >
                Clear search
              </Button>
            )}
          </div>
        )}
      </div>
      <p className="text-xs text-muted-foreground">
        {data.rows.length} source entries shown. Amounts and reconciliation status come from the
        recorded sources.
      </p>
    </div>
  );
}
