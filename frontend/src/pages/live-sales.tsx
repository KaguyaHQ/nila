import {
  Empty,
  EmptyHeader,
  EmptyTitle,
  EmptyDescription,
  EmptyContent,
} from "@/components/ui/empty";
import { WorkspaceError } from "@/components/workspace-error";
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
import { SalesUploadDialog } from "@/pages/live-sales-uploads";
import { salesSearch } from "@/lib/route-search";
import { urlDestination } from "@/lib/route-url";
import { ApiError, fetchSales, type SalesWorkspace } from "@/lib/sales-api";
import { SalesWorkspaceContext, useSales } from "@/state/sales-workspace";
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
import { useContext } from "react";
import { useSalesRegisterScroll } from "@/lib/sales-register-scroll";
import { SelectField, SelectFieldOption } from "@/components/ui/select-field";
import { SalesRecordInspector } from "@/components/sales-record-inspector";
import { ReturnReview } from "@/components/return-review";
import { SalesReportChecks } from "@/components/sales-report-checks";

const Workspace = SalesWorkspaceContext;
const money = (value: string | null) => value ?? "—";

export function LiveSalesLayout() {
  const { clientId, period } = useParams({ from: "/gst/$clientId/$period" });
  const { pathname } = useLocation();
  const search = useSearch({ from: "/gst/$clientId/$period" });
  const navigate = useNavigate();
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
      <WorkspaceError
        title="Sales unavailable"
        message={query.error.message}
        needsSignIn={query.error instanceof ApiError && query.error.status === 401}
        retry={() => {
          void query.refetch();
        }}
        backToClients={true}
      />
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
      {!loading && (
        <SalesUploadDialog
          data={query.data}
          open={search.upload === "invoices"}
          onOpenChange={(open) =>
            navigate({
              to: pathname,
              search: { ...search, upload: open ? "invoices" : undefined },
              replace: true,
            })
          }
        />
      )}
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
          <h1 aria-label={data.month_label} className="w-72 shrink-0">
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
          onClick={() =>
            navigate({
              to: register
                ? "/gst/$clientId/$period/sales/register"
                : "/gst/$clientId/$period/sales",
              params: { clientId: String(data.client.id), period: data.period },
              search: { ...search, upload: "invoices" },
              replace: true,
            })
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
  const search = useSearch({ from: "/gst/$clientId/$period" });
  const unprepared = data.invoice_count === 0 && data.rows.length === 0;
  const emptyMonth = unprepared && data.uploads.files === 0 && !data.uploads.unfinished;
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
              {(data.report_count ?? 0) > 0
                ? "Imported sales and credit notes."
                : data.invoice_count
                  ? `${data.review_count} invoices need review.`
                  : emptyMonth
                    ? "Add sales bills to prepare this month's working."
                    : "No invoices in the working yet."}
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
            [
              (data.report_count ?? 0) > 0 ? "Invoices and credit notes" : "Invoices in working",
              String(data.invoice_count),
            ],
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
      <div
        className={`mt-8 grid items-start gap-7 ${emptyMonth ? "" : "xl:grid-cols-[minmax(0,1fr)_220px]"}`}
      >
        <section aria-labelledby="gstr1-summary" className="min-w-0">
          <h2 id="gstr1-summary" className="mb-3 text-sm font-semibold">
            GSTR-1 summary
          </h2>
          {unprepared && (
            <p className="mb-3 text-sm text-muted-foreground">
              {emptyMonth
                ? `No sales invoices added for ${data.month_label} yet.`
                : "Sections will populate once sales invoices are prepared."}
            </p>
          )}
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
                    <TableCell className="text-right whitespace-nowrap">
                      {unprepared ? "—" : section.count}
                    </TableCell>
                    <TableCell className="text-right whitespace-nowrap tabular-nums">
                      {unprepared ? "—" : money(section.value)}
                    </TableCell>
                    <TableCell>
                      {unprepared && section.status === "No entries" ? (
                        <span className="text-xs text-muted-foreground">—</span>
                      ) : section.status === "No entries" ? (
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
        {!emptyMonth && (
          <aside className="xl:border-l xl:pl-6">
            <SalesExports data={data} />
          </aside>
        )}
      </div>
      {!emptyMonth && (
        <div className="mt-8">
          <ReturnReview data={data} selectedTask={search.returnTask} />
        </div>
      )}
    </>
  );
}

export function LiveSalesRegister() {
  const data = useSales();
  const params = useSearch({ from: "/gst/$clientId/$period/sales/register" });
  const navigate = useNavigate({ from: "/gst/$clientId/$period/sales/register" });
  useSalesRegisterScroll(
    JSON.stringify([
      data.client.id,
      data.period,
      params.q,
      params.filter,
      params.issue,
      params.buyer,
    ]),
  );
  const filter = params.filter ?? "all";
  const search = params.q ?? "";
  const codes = new Map<string, string>();
  data.rows.forEach((row) => row.issues?.forEach((issue) => codes.set(issue.code, issue.title)));
  const filtered = data.rows.filter(
    (row) =>
      (filter === "all" || row.status === filter) &&
      (!params.issue ||
        params.issue === "report_notes" ||
        row.issues?.some((issue) => issue.code === params.issue)) &&
      `${row.number} ${row.customer} ${row.gstin ?? ""}`
        .toLowerCase()
        .includes(search.trim().toLowerCase()),
  );
  const buyers = new Map<string, { name: string; count: number }>();
  filtered.forEach((row) => {
    if (row.gstin) {
      const existing = buyers.get(row.gstin);
      buyers.set(row.gstin, { name: row.customer, count: (existing?.count ?? 0) + 1 });
    }
  });
  const visible = filtered.filter((row) => !params.buyer || row.gstin === params.buyer);
  const selected = data.rows.find((row) => row.id === params.selected && row.path);
  const update = (changes: Partial<typeof params>) =>
    void navigate({
      search: { ...params, ...changes },
      resetScroll: false,
      replace: Object.hasOwn(changes, "q"),
    });
  const rowSearch = (id: string) => ({ ...params, selected: id });
  const reviewUrl = selected?.path
    ? `${selected.path}?${new URLSearchParams(Object.entries({ ...params, origin: "register", selected: selected.id }).filter((entry): entry is [string, string] => typeof entry[1] === "string"))}`
    : "";
  const registration =
    params.issue?.includes("gstin") ||
    params.issue?.includes("registration") ||
    params.issue?.includes("buyer_name");
  return (
    <>
      <Link
        to="/gst/$clientId/$period/sales"
        params={{ clientId: String(data.client.id), period: data.period }}
        className="mb-5 inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="size-4" /> Return summary
      </Link>
      <PeriodHeading register />
      <div className="mb-4 flex flex-wrap items-center gap-3">
        <ToggleGroup
          aria-label="Filter invoices by status"
          size="sm"
          value={[filter]}
          onValueChange={(values) => {
            if (values[0])
              update({
                filter: salesSearch({ filter: values[0] }).filter,
                selected: undefined,
                buyer: undefined,
              });
          }}
        >
          {[
            ["all", "All"],
            ["needs_review", "Needs attention"],
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
        <div className="relative ml-auto w-72">
          <Search className="absolute left-3 top-2.5 size-4 text-muted-foreground" />
          <Input
            data-shortcut-search
            aria-label="Search customer, invoice or GSTIN"
            placeholder="Search customer, invoice or GSTIN"
            className="pl-9"
            value={search}
            onChange={(event) =>
              update({ q: event.target.value || undefined, selected: undefined })
            }
          />
        </div>
      </div>
      <div className="mb-4 flex flex-wrap items-center gap-3">
        <SelectField
          aria-label="Check type"
          value={params.returnTask ? "report_notes" : (params.issue ?? "")}
          onValueChange={(nextValue) =>
            update({
              issue: nextValue || undefined,
              returnTask: undefined,
              buyer: undefined,
              selected: undefined,
            })
          }
        >
          <SelectFieldOption value="">All checks</SelectFieldOption>
          {[...codes].map(([code, title]) => (
            <SelectFieldOption key={code} value={code}>
              {title}
            </SelectFieldOption>
          ))}
          {(data.report_count ?? 0) > 0 && <SelectFieldOption value="report_notes">Note treatment</SelectFieldOption>}
        </SelectField>
        <SelectField
          aria-label="Buyer group"
          value={params.buyer ?? ""}
          onValueChange={(nextValue) => {
            const buyer = nextValue || undefined;
            update({
              buyer,
              selected: buyer ? filtered.find((row) => row.gstin === buyer)?.id : undefined,
            });
          }}
        >
          <SelectFieldOption value="">All buyers</SelectFieldOption>
          {[...buyers].map(([gstin, buyer]) => (
            <SelectFieldOption key={gstin} value={gstin}>
              {buyer.name} · {buyer.count} {buyer.count === 1 ? "invoice" : "invoices"}
            </SelectFieldOption>
          ))}
        </SelectField>
        {(params.issue || params.buyer || search) && (
          <Button
            variant="ghost"
            size="sm"
            onClick={() =>
              update({
                issue: undefined,
                returnTask: undefined,
                buyer: undefined,
                q: undefined,
                selected: undefined,
              })
            }
          >
            Clear filters
          </Button>
        )}
      </div>
      {params.issue === "report_notes" || params.returnTask ? (
        <SalesReportChecks data={data} scope="sales" selectedTask={params.returnTask} />
      ) : (
        <>
          {registration && !params.buyer && (
            <div className="mb-4 flex flex-wrap gap-2" aria-label="Affected buyers">
              {[...buyers].map(([gstin, buyer]) => (
                <Button
                  key={gstin}
                  variant="outline"
                  size="sm"
                  onClick={() =>
                    update({
                      buyer: gstin,
                      selected: filtered.find((row) => row.gstin === gstin)?.id,
                    })
                  }
                >
                  {buyer.name} · {buyer.count}
                </Button>
              ))}
            </div>
          )}
          <div className={selected ? "grid items-start gap-4 grid-cols-[minmax(0,1fr)_420px]" : ""}>
            <section
              className="min-w-0 overflow-hidden rounded-xl border bg-card"
              aria-label="Sales invoices"
            >
              {params.buyer && (
                <div className="flex items-center justify-between gap-3 border-b px-4 py-3">
                  <div>
                    <h2 className="text-sm font-semibold">
                      {buyers.get(params.buyer)?.name ?? params.buyer}
                    </h2>
                    <p className="text-xs text-muted-foreground">
                      {params.buyer} · {visible.length} affected invoices
                    </p>
                  </div>
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => update({ buyer: undefined, selected: undefined })}
                  >
                    All buyers
                  </Button>
                </div>
              )}
              <Table>
                <TableHeader>
                  <TableRow>
                    <TableHead className="pl-4">Invoice / Customer</TableHead>
                    {!selected && <TableHead>Date</TableHead>}
                    <TableHead className="text-right">Taxable</TableHead>
                    {!selected && <TableHead className="text-right">GST</TableHead>}
                    <TableHead>Needs attention</TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {visible.map((row) => (
                    <RecordTableRow
                      key={row.id}
                      data-state={selected?.id === row.id ? "selected" : undefined}
                    >
                      <TableCell className="py-3 pl-4">
                        {row.path ? (
                          <RecordTableLink
                            to="/gst/$clientId/$period/sales/register"
                            params={{ clientId: String(data.client.id), period: data.period }}
                            search={rowSearch(row.id)}
                            resetScroll={false}
                            className="font-medium hover:underline"
                            aria-label={`Inspect invoice ${row.number}`}
                          >
                            {row.number}
                          </RecordTableLink>
                        ) : (
                          <span className="font-medium">{row.number}</span>
                        )}
                        <p className="mt-1 max-w-64 whitespace-normal text-xs text-muted-foreground">
                          {row.customer}
                        </p>
                      </TableCell>
                      {!selected && (
                        <TableCell className="whitespace-nowrap">{row.date ?? "—"}</TableCell>
                      )}
                      <TableCell className="text-right tabular-nums">
                        {money(row.taxable)}
                      </TableCell>
                      {!selected && (
                        <TableCell className="text-right tabular-nums">{money(row.tax)}</TableCell>
                      )}
                      <TableCell>
                        <p className="max-w-56 whitespace-normal text-xs">
                          {row.reason ||
                            (row.status === "ready"
                              ? "Ready"
                              : row.status === "excluded"
                                ? "Excluded"
                                : "Needs review")}
                        </p>
                      </TableCell>
                    </RecordTableRow>
                  ))}
                  {!visible.length && (
                    <TableRow>
                      <TableCell colSpan={selected ? 3 : 5}>
                        <Empty>
                          <EmptyHeader>
                            <EmptyTitle>
                              {data.rows.length ? "No invoices match" : "No sales invoices yet"}
                            </EmptyTitle>
                            <EmptyDescription>
                              {data.rows.length
                                ? "Try another search or clear the filters."
                                : "Add sales bills to prepare this month."}
                            </EmptyDescription>
                          </EmptyHeader>
                          <EmptyContent>
                            <Button
                              variant="outline"
                              onClick={() => void navigate({ search: {}, resetScroll: false })}
                            >
                              Clear filters
                            </Button>
                          </EmptyContent>
                        </Empty>
                      </TableCell>
                    </TableRow>
                  )}
                </TableBody>
              </Table>
              <p
                role="status"
                className="border-t bg-muted/20 px-4 py-3 text-xs text-muted-foreground"
              >
                Showing {visible.length} of {data.rows.length} invoices
              </p>
            </section>
            {selected && (
              <SalesRecordInspector
                key={selected.id}
                clientId={String(data.client.id)}
                period={data.period}
                invoiceId={selected.id}
                issue={params.issue}
                affectedCount={params.buyer ? visible.length : 1}
                reviewUrl={reviewUrl}
                onClose={() => update({ selected: undefined })}
              />
            )}
          </div>
        </>
      )}
    </>
  );
}
