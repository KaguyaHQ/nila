import { MonthPicker } from "@/components/month-picker";
import { RecordTableLink, RecordTableRow } from "@/components/record-table-row";
import { SalesExports } from "@/components/sales-exports";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { Shell } from "@/components/workspace-shell";
import { salesSearch } from "@/lib/route-search";
import { urlDestination } from "@/lib/route-url";
import { ApiError, fetchSales, type SalesWorkspace } from "@/lib/sales-api";
import { useQuery } from "@tanstack/react-query";
import { Link, useLocation, useNavigate, useParams, useSearch } from "@tanstack/react-router";
import {
  ArrowLeft,
  ArrowRight,
  ChevronLeft,
  ChevronRight,
  Plus,
  Search,
  Upload,
} from "lucide-react";
import { createContext, useContext } from "react";

const Workspace = createContext<SalesWorkspace | null>(null);
export function useSales() {
  const data = useContext(Workspace);
  if (!data) throw new Error("Sales workspace is missing");
  return data;
}
const money = (value: string | null) => value ?? "—";

export function LiveSalesLayout() {
  const { clientId, period } = useParams({ from: "/gst/$clientId/$period" });
  const { pathname } = useLocation();
  const query = useQuery({
    queryKey: ["sales", clientId, period],
    queryFn: ({ signal }) => fetchSales(clientId, period, signal),
    // Retain same-client navigation metadata only. Never render its old figures.
    placeholderData: (previous) =>
      previous?.client.id === Number(clientId) ? previous : undefined,
    staleTime: 0,
    retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 1,
    refetchInterval: (query) => (query.state.data?.uploads.unfinished ? 5000 : false),
  });

  if (query.isPending)
    return (
      <main className="mx-auto max-w-7xl px-10 py-16" aria-busy="true">
        <SalesLoading />
      </main>
    );
  // Never leave another client's cached figures on screen after authorization fails.
  if (query.isError)
    return (
      <main className="mx-auto max-w-xl px-6 py-24">
        <h1 className="text-2xl font-semibold">Sales unavailable</h1>
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
        <a href="/clients" className="ml-5 text-sm underline">
          Back to clients
        </a>
      </main>
    );

  const loading = query.isPlaceholderData;
  const base = `/gst/${clientId}/${period}/sales`;
  return (
    <Workspace.Provider value={loading ? null : query.data}>
      <Shell
        live={{
          ...query.data,
          base,
          purchases: `/gst/${clientId}/${period}/purchases`,
        }}
      >
        {loading ? (
          <>
            <PeriodHeading
              register={pathname.endsWith("/register")}
              loading
              data={{
                client: query.data.client,
                period,
                invoice_count: 0,
                month_label: new Intl.DateTimeFormat("en-IN", {
                  month: "long",
                  year: "numeric",
                  timeZone: "UTC",
                }).format(new Date(`${period}-01T12:00:00Z`)),
              }}
            />
            <SalesLoading register={pathname.endsWith("/register")} />
          </>
        ) : undefined}
      </Shell>
    </Workspace.Provider>
  );
}

function SalesLoading({ register = false }: { register?: boolean }) {
  return (
    <div role="status" aria-label="Loading sales" aria-busy="true" className="space-y-6">
      <span className="sr-only">Loading sales…</span>
      <div aria-hidden="true" className="space-y-6">
        <Card className="p-6 shadow-none">
          <Skeleton className="h-4 w-32" />
          <Skeleton className="h-4 w-72" />
          <div className="flex gap-8">
            <Skeleton className="h-6 w-36" />
            <Skeleton className="h-6 w-36" />
            <Skeleton className="h-6 w-36" />
          </div>
        </Card>
        <div className={register ? "" : "grid grid-cols-[minmax(0,1fr)_280px] gap-6"}>
          <Card className="p-6 shadow-none">
            <Skeleton className="h-5 w-40" />
            {Array.from({ length: 7 }, (_, i) => (
              <div key={i} className="flex justify-between border-t py-3">
                <Skeleton className="h-4 w-52" />
                <Skeleton className="h-4 w-24" />
              </div>
            ))}
          </Card>
          {!register && (
            <Card className="h-fit p-6 shadow-none">
              <Skeleton className="h-5 w-24" />
              <Skeleton className="h-4 w-full" />
              <Skeleton className="h-9 w-full" />
              <Skeleton className="h-9 w-full" />
            </Card>
          )}
        </div>
      </div>
    </div>
  );
}

function PeriodHeading({
  register = false,
  loading = false,
  data: supplied,
}: {
  register?: boolean;
  loading?: boolean;
  data?: Pick<SalesWorkspace, "client" | "period" | "month_label" | "invoice_count">;
}) {
  const workspace = useContext(Workspace);
  const data = supplied ?? workspace!;
  const navigate = useNavigate();
  const search = useSearch({ from: "/gst/$clientId/$period" });
  const go = (clientId: string, period: string) =>
    navigate({
      to: register ? "/gst/$clientId/$period/sales/register" : "/gst/$clientId/$period/sales",
      params: { clientId, period },
      search,
    });
  const shift = (delta: number) => {
    const date = new Date(`${data.period}-01T12:00:00Z`);
    date.setUTCMonth(date.getUTCMonth() + delta);
    go(String(data.client.id), date.toISOString().slice(0, 7));
  };
  const current = new Date().toISOString().slice(0, 7);

  return (
    <div className="mb-8 flex flex-wrap items-end justify-between gap-5">
      <div className="flex flex-wrap items-center gap-3">
        {register ? (
          <>
            <h1 className="text-3xl font-semibold tracking-tight">Sales register</h1>
            <MonthPicker
              period={data.period}
              label={data.month_label}
              max={current}
              onSelect={(period) => go(String(data.client.id), period)}
            />
          </>
        ) : (
          <h1 aria-label={data.month_label}>
            <MonthPicker
              large
              period={data.period}
              label={data.month_label}
              max={current}
              onSelect={(period) => go(String(data.client.id), period)}
            />
          </h1>
        )}
        <div className="flex">
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
      </div>
      {loading ? (
        <Skeleton aria-hidden="true" className="h-9 w-32" />
      ) : (
        <Button
          variant={data.invoice_count ? "outline" : "default"}
          nativeButton={false}
          role="link"
          render={
            <Link
              to="/gst/$clientId/$period/sales/upload"
              params={{ clientId: String(data.client.id), period: data.period }}
            />
          }
        >
          <Plus /> Add invoices
        </Button>
      )}
    </div>
  );
}

export function LiveSalesSummary() {
  const data = useSales();
  return (
    <>
      <PeriodHeading />
      {data.uploads.unfinished && (
        <p role="status" className="mb-5 rounded-lg border bg-muted/40 px-4 py-3 text-sm">
          Some uploads are still being read or need attention.{" "}
          <Link
            to="/gst/$clientId/$period/sales/uploads"
            params={{ clientId: String(data.client.id), period: data.period }}
            className="font-medium underline"
          >
            Check uploads
          </Link>
        </p>
      )}
      <Card className="gap-0 overflow-hidden py-0 shadow-none">
        <div className="flex flex-wrap items-center justify-between gap-4 px-6 pt-5">
          <div>
            <h2 className="text-sm font-semibold">Sales invoices</h2>
            <p className="mt-1 text-sm text-muted-foreground">
              {data.invoice_count
                ? `${data.review_count} invoices need review.`
                : "Add sales bills to prepare this month's working."}
            </p>
          </div>
          {data.review_count > 0 && (
            <Button
              nativeButton={false}
              role="link"
              render={
                <Link
                  to="/gst/$clientId/$period/sales/register"
                  params={{ clientId: String(data.client.id), period: data.period }}
                  search={{ filter: "needs_review" }}
                />
              }
            >
              Review invoices <ArrowRight />
            </Button>
          )}
        </div>
        <div className="grid gap-5 px-6 py-6 sm:grid-cols-[.75fr_1fr_1fr]">
          {[
            ["Invoices in working", String(data.invoice_count)],
            ["Taxable value", money(data.taxable)],
            ["Output tax", money(data.tax)],
          ].map(([label, value], i) => (
            <div key={label} className={i ? "sm:border-l sm:pl-6" : ""}>
              <p className="text-xs text-muted-foreground">{label}</p>
              <p className="mt-1.5 text-2xl font-semibold tracking-tight tabular-nums">{value}</p>
            </div>
          ))}
        </div>
        <div className="flex flex-wrap items-center justify-between gap-2 border-t bg-muted/20 px-4 py-2">
          <Button
            variant="ghost"
            size="sm"
            nativeButton={false}
            role="link"
            render={
              <Link
                to="/gst/$clientId/$period/sales/register"
                params={{ clientId: String(data.client.id), period: data.period }}
              />
            }
          >
            View sales register <ArrowRight />
          </Button>
          <Button
            variant="ghost"
            size="sm"
            nativeButton={false}
            role="link"
            render={
              <Link
                to="/gst/$clientId/$period/sales/uploads"
                params={{ clientId: String(data.client.id), period: data.period }}
              />
            }
          >
            <Upload /> Uploads · {data.uploads.files} {data.uploads.files === 1 ? "file" : "files"}
          </Button>
        </div>
      </Card>
      {data.month_issue_count > 0 && (
        <p className="mt-5 text-sm">
          <Link
            to="/gst/$clientId/$period/sales/checks"
            params={{ clientId: String(data.client.id), period: data.period }}
            className="font-medium underline underline-offset-4"
          >
            Review {data.month_issue_count} month{" "}
            {data.month_issue_count === 1 ? "check" : "checks"}
          </Link>
          <span className="text-muted-foreground"> before downloading GSTR-1 JSON.</span>
        </p>
      )}
      <div className="mt-8 grid items-start gap-7 xl:grid-cols-[minmax(0,1fr)_220px]">
        <section aria-labelledby="gstr1-summary" className="min-w-0">
          <h2 id="gstr1-summary" className="mb-3 text-sm font-semibold">
            GSTR-1 summary
          </h2>
          <div className="overflow-hidden rounded-xl border bg-white">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="pl-4">Section</TableHead>
                  <TableHead className="text-right">Entries</TableHead>
                  <TableHead className="text-right">Taxable value</TableHead>
                  <TableHead>Status</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.sections.map((section) => (
                  <RecordTableRow key={section.id}>
                    <TableCell className="py-3 pl-4">
                      {section.path ? (
                        <RecordTableLink
                          to="/gst/$clientId/$period/sales/sections/$section"
                          params={{
                            clientId: String(data.client.id),
                            period: data.period,
                            section: section.id,
                          }}
                          className="font-medium hover:underline"
                        >
                          {section.label}
                        </RecordTableLink>
                      ) : (
                        section.label
                      )}
                    </TableCell>
                    <TableCell className="text-right whitespace-nowrap">{section.count}</TableCell>
                    <TableCell className="text-right whitespace-nowrap tabular-nums">
                      {money(section.value)}
                    </TableCell>
                    <TableCell>
                      {section.status === "No entries" ? (
                        <span className="text-xs text-muted-foreground">No entries</span>
                      ) : (
                        <Badge
                          variant="secondary"
                          className={
                            section.variant === "warning"
                              ? "bg-amber-50 text-amber-800"
                              : section.variant === "success"
                                ? "bg-emerald-50 text-emerald-800"
                                : "font-normal text-muted-foreground"
                          }
                        >
                          {section.status}
                        </Badge>
                      )}
                    </TableCell>
                  </RecordTableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        </section>
        <aside className="xl:border-l xl:pl-6">
          <SalesExports data={data} />
        </aside>
      </div>
    </>
  );
}

export function LiveSalesRegister() {
  const data = useSales();
  const params = useSearch({ from: "/gst/$clientId/$period/sales/register" });
  const setParams = useNavigate({ from: "/gst/$clientId/$period/sales/register" });
  const filter = ["needs_review", "ready", "excluded"].includes(params.filter ?? "")
    ? params.filter!
    : "all";
  const search = params.q ?? "";
  const visible = data.rows.filter(
    (row) =>
      (filter === "all" || row.status === filter) &&
      `${row.number} ${row.customer} ${row.gstin ?? ""}`
        .toLowerCase()
        .includes(search.trim().toLowerCase()),
  );
  function set(key: "filter" | "q", value: string) {
    setParams({
      search: {
        ...params,
        ...(key === "filter"
          ? { filter: salesSearch({ filter: value }).filter }
          : { q: value || undefined }),
      },
      resetScroll: false,
      replace: key === "q",
    });
  }
  return (
    <>
      <Link
        to="/gst/$clientId/$period/sales"
        params={{ clientId: String(data.client.id), period: data.period }}
        className="mb-5 inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="size-4" />
        Sales summary
      </Link>
      <PeriodHeading register />
      <section className="overflow-hidden rounded-xl border bg-card" aria-label="Sales invoices">
        <div className="flex flex-wrap items-center justify-between gap-4 border-b p-4">
          <ToggleGroup
            aria-label="Filter invoices by status"
            className="flex-wrap"
            size="sm"
            value={[filter]}
            onValueChange={(values) => {
              const value = values[0];
              if (value) set("filter", value === "all" ? "" : value);
            }}
          >
            {[
              ["all", "All invoices"],
              ["needs_review", "Needs review"],
              ["ready", "Ready"],
              ["excluded", "Excluded"],
            ].map(([value, label]) => (
              <ToggleGroupItem key={value} value={value}>
                {label}
                <span className="ml-1 text-muted-foreground">
                  {data.rows.filter((row) => value === "all" || row.status === value).length}
                </span>
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
          <div className="relative w-full sm:w-72">
            <Search className="absolute top-2.5 left-3 size-4 text-muted-foreground" />
            <Input
              data-shortcut-search
              aria-label="Search customer, invoice or GSTIN"
              placeholder="Search customer, invoice or GSTIN"
              className="pl-9"
              value={search}
              onChange={(e) => set("q", e.target.value)}
            />
          </div>
        </div>
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="pl-5">Invoice</TableHead>
              <TableHead>Date</TableHead>
              <TableHead>Customer</TableHead>
              <TableHead className="text-right">Taxable value</TableHead>
              <TableHead className="text-right">GST</TableHead>
              <TableHead>Status</TableHead>
              <TableHead>
                <span className="sr-only">Review invoice</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {visible.map((row) => (
              <RecordTableRow key={row.id}>
                <TableCell className="py-4 pl-5">
                  {row.path ? (
                    <Link
                      {...urlDestination(
                        `${row.path}?${new URLSearchParams({ filter: filter === "needs_review" || filter === "ready" ? filter : "all", ...(search ? { q: search } : {}) })}`,
                      )}
                      className="font-medium hover:underline"
                    >
                      {row.number}
                    </Link>
                  ) : (
                    <span className="font-medium">{row.number}</span>
                  )}
                </TableCell>
                <TableCell className="whitespace-nowrap">{row.date ?? "—"}</TableCell>
                <TableCell>
                  <p className="max-w-72 whitespace-normal font-medium">{row.customer}</p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {row.gstin || "GSTIN not recorded"}
                  </p>
                </TableCell>
                <TableCell className="text-right whitespace-nowrap tabular-nums">
                  {money(row.taxable)}
                </TableCell>
                <TableCell className="text-right whitespace-nowrap tabular-nums">
                  {money(row.tax)}
                </TableCell>
                <TableCell>
                  <Badge
                    variant="secondary"
                    className={row.status === "needs_review" ? "bg-amber-50 text-amber-800" : ""}
                  >
                    {row.status === "needs_review"
                      ? "Needs review"
                      : row.status === "ready"
                        ? "Ready"
                        : "Excluded"}
                  </Badge>
                  {row.reason && (
                    <p className="mt-1 max-w-60 whitespace-normal text-xs text-muted-foreground">
                      {row.reason}
                    </p>
                  )}
                </TableCell>
                <TableCell className="pr-5 text-right">
                  {row.path && (
                    <RecordTableLink
                      {...urlDestination(
                        `${row.path}?${new URLSearchParams({ filter: filter === "needs_review" || filter === "ready" ? filter : "all", ...(search ? { q: search } : {}) })}`,
                      )}
                      aria-label={`Review invoice ${row.number}`}
                      className="inline-flex items-center gap-1 font-medium hover:underline"
                    >
                      Review <ArrowRight className="size-4" aria-hidden="true" />
                    </RecordTableLink>
                  )}
                </TableCell>
              </RecordTableRow>
            ))}
            {visible.length === 0 && (
              <TableRow>
                <TableCell colSpan={7} className="py-14 text-center">
                  <p className="font-medium">
                    {data.rows.length ? "No invoices match" : "No sales invoices yet"}
                  </p>
                  <p className="mt-2 text-muted-foreground">
                    {data.rows.length
                      ? "Try another search or clear the filters."
                      : "Add sales bills to build this month's register."}
                  </p>
                  {data.review_count > 0 && (
                    <Button
                      variant="outline"
                      className="mt-4"
                      onClick={() => setParams({ search: {}, resetScroll: false })}
                    >
                      Clear filters
                    </Button>
                  )}
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
        <p role="status" className="border-t bg-muted/20 px-5 py-3 text-sm text-muted-foreground">
          Showing {visible.length} of {data.rows.length} invoices
        </p>
      </section>
      <p className="mt-4 text-xs text-muted-foreground">
        Register amounts are extracted from source invoices. The summary shows their contribution to
        the GST working.
      </p>
    </>
  );
}
