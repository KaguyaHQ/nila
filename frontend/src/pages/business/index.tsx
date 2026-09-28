import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Link,
  Navigate,
  Outlet,
  useBlocker,
  useLocation,
  useNavigate,
  useParams,
  useSearch,
} from "@tanstack/react-router";
import { ArrowLeft, ChevronsUpDown, Download, FileText, Plus, Trash2 } from "lucide-react";
import {
  createContext,
  type FormEvent,
  lazy,
  type ReactNode,
  Suspense,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { type InvoiceCalculation, InvoiceDocument } from "@/components/business/invoice-document";
import { AddBusinessDialog } from "@/components/business/add-business-dialog";
import { StateCombobox } from "@/components/business/state-combobox";
import { RecordTableLink, RecordTableRow } from "@/components/record-table-row";
import { Badge } from "@/components/ui/badge";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { Input } from "@/components/ui/input";
import { SelectField, SelectFieldOption } from "@/components/ui/select-field";
import { Spinner } from "@/components/ui/spinner";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { Textarea } from "@/components/ui/textarea";
import {
  BusinessApiError,
  type BusinessBootstrap,
  type BusinessCustomer,
  type BusinessCustomerAddress,
  type BusinessInvoice,
  type BusinessLine,
  businessRequest,
  listBusinessWorkspaces,
  downloadInvoice,
  fetchInvoicePdf,
  type InvoiceInput,
  uploadBusinessBrandAsset,
} from "@/lib/business-api";
import { ServicesPage } from "./services";

const SourcePdf = lazy(() => import("@/components/source-pdf"));
const Workspace = createContext<BusinessBootstrap | null>(null);
const businessQueryKey = (businessId: string) => ["business", businessId];
const retry = (count: number, error: Error) =>
  !(error instanceof BusinessApiError && error.status < 500) && count < 1;
const money = (paise: number) =>
  new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(paise / 100);
function useBusiness() {
  const value = useContext(Workspace);
  if (!value) throw new Error("Business workspace missing");
  return value;
}
export function useBusinessId() {
  const { businessId } = useParams({ strict: false }) as { businessId: string };
  if (!businessId) throw new Error("Business ID missing");
  return businessId;
}
export function BusinessIndex() {
  const [addBusinessOpen, setAddBusinessOpen] = useState(false);
  const query = useQuery({
    queryKey: ["business-workspaces"],
    queryFn: ({ signal }) => listBusinessWorkspaces(signal),
    retry,
  });
  if (query.isPending) {
    return <main className="mx-auto max-w-xl p-8"><p role="status">Loading your businesses…</p></main>;
  }
  if (query.isError) {
    return <main className="mx-auto max-w-xl space-y-4 p-8">
      <Errors error={query.error} />
      <Button onClick={() => query.refetch()}>Try again</Button>
    </main>;
  }
  const businesses = query.data.businesses;
  if (businesses.length === 1) {
    return <Navigate to="/business/$businessId/invoices" params={{ businessId: String(businesses[0].id) }} replace />;
  }
  return (
    <main className="mx-auto max-w-xl space-y-6 p-8">
      <h1 className="text-2xl font-semibold">Your businesses</h1>
      {businesses.length ? (
        <ul className="space-y-2">
          {businesses.map((business) => (
            <li key={business.id}>
              <Link className="block rounded-lg border p-4 hover:bg-muted" to="/business/$businessId/invoices" params={{ businessId: String(business.id) }}>
                <span className="font-medium">{business.name}</span>
                {business.gstin && <span className="ml-3 text-sm text-muted-foreground">{business.gstin}</span>}
              </Link>
            </li>
          ))}
        </ul>
      ) : (
        <p className="text-sm text-muted-foreground">You don't have a business yet.</p>
      )}
      <Button variant="outline" onClick={() => setAddBusinessOpen(true)}><Plus /> Add business</Button>
      <AddBusinessDialog open={addBusinessOpen} onOpenChange={setAddBusinessOpen} />
      {query.data.ca_workspace.available && <p><a className="underline underline-offset-4" href="/app">Open CA workspace</a></p>}
    </main>
  );
}
function Field({ label, id, children }: { label: string; id: string; children: ReactNode }) {
  return (
    <div className="min-w-0 space-y-2">
      <label htmlFor={id} className="text-sm font-medium">
        {label}
      </label>
      {children}
    </div>
  );
}
function Errors({ error }: { error: Error | null }) {
  return error ? (
    <div role="alert" className="rounded-md border border-destructive/30 p-4 text-sm">
      <p>{error.message}</p>
      {error instanceof BusinessApiError && Object.entries(error.fields).length > 0 && (
        <ul className="mt-2 list-inside list-disc">
          {Object.entries(error.fields).map(([key, value]) => (
            <li key={key}>
              {key.replaceAll("_", " ")}:{" "}
              {typeof value === "string" ? value : JSON.stringify(value)}
            </li>
          ))}
        </ul>
      )}
    </div>
  ) : null;
}
function StateSelect({
  id,
  value,
  onChange,
}: {
  id: string;
  value: string;
  onChange: (value: string) => void;
}) {
  const data = useBusiness();
  return <StateCombobox id={id} states={data.states} value={value} onChange={onChange} required />;
}
export function BusinessLayout() {
  const businessId = useBusinessId();
  const [addBusinessOpen, setAddBusinessOpen] = useState(false);
  const [workspaceMenuOpen, setWorkspaceMenuOpen] = useState(false);
  const location = useLocation();
  const editingInvoice = /\/business\/[^/]+\/(?:invoices|quotations)\/.+/.test(location.pathname);
  const query = useQuery({
    queryKey: businessQueryKey(businessId),
    queryFn: ({ signal }) => businessRequest("getBusinessBootstrap", { businessId, signal }),
    retry,
  });
  const workspaces = useQuery({
    queryKey: ["business-workspaces"],
    queryFn: ({ signal }) => listBusinessWorkspaces(signal),
    retry,
  });
  if (query.isPending)
    return (
      <main className="mx-auto max-w-5xl p-8">
        <p role="status">Loading your business…</p>
      </main>
    );
  if (query.isError)
    return (
      <main className="mx-auto max-w-xl space-y-4 p-8">
        <h1 className="text-2xl font-semibold">Business workspace unavailable</h1>
        <Errors error={query.error} />
        {query.error instanceof BusinessApiError && query.error.status === 401 ? (
          <a className="underline" href="/users/log_in">
            Sign in
          </a>
        ) : query.error instanceof BusinessApiError && query.error.status === 403 ? (
          <>
            <p className="text-sm text-muted-foreground">
              You don't have access to this business. Choose another business or return to your CA workspace.
            </p>
            <div className="flex flex-wrap gap-3">
              <Button nativeButton={false} role="link" render={<a href="/app" />}>
                Open Nila
              </Button>
              <Button nativeButton={false} variant="outline" role="link" render={<a href="/app/business" />}>
                Choose business
              </Button>
              <form action="/users/log_out" method="post">
                <Input type="hidden" name="_method" value="delete" />
                <Input
                  type="hidden"
                  name="_csrf_token"
                  value={
                    document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ??
                    ""
                  }
                />
                <Button type="submit" variant="outline">
                  Sign out
                </Button>
              </form>
            </div>
          </>
        ) : (
          <Button onClick={() => query.refetch()}>Try again</Button>
        )}
      </main>
    );
  return (
    <Workspace.Provider value={query.data}>
      <div className="min-h-screen bg-background text-foreground">
        <header className="border-b">
          <div
            className={`mx-auto flex flex-wrap items-center justify-between gap-4 px-4 py-4 sm:px-8 ${editingInvoice ? "max-w-[1440px]" : "max-w-6xl"}`}
          >
            <Link to="/business/$businessId/invoices" params={{ businessId }} className="font-semibold">
              Nila
            </Link>
            <div className="flex items-center gap-3">
              <DropdownMenu open={workspaceMenuOpen} onOpenChange={setWorkspaceMenuOpen}>
                <DropdownMenuTrigger
                  aria-label="Business"
                  render={<Button variant="outline" className="max-w-64" />}
                >
                  <span className="truncate">{query.data.business.name}</span>
                  <ChevronsUpDown className="ml-2 size-4 shrink-0 text-muted-foreground" />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="start">
                  {(workspaces.data?.businesses ?? [{
                    id: Number(businessId),
                    name: query.data.business.name,
                    gstin: query.data.business.gstin,
                  }]).map((item) => (
                    <DropdownMenuItem key={item.id} render={<a href={`/app/business/${item.id}/invoices`} />}>
                      {item.name}
                    </DropdownMenuItem>
                  ))}
                  <DropdownMenuSeparator />
                  <DropdownMenuItem onClick={() => { setWorkspaceMenuOpen(false); setAddBusinessOpen(true); }}>
                    <Plus /> Add business
                  </DropdownMenuItem>
                </DropdownMenuContent>
              </DropdownMenu>
              <AddBusinessDialog open={addBusinessOpen} onOpenChange={setAddBusinessOpen} />
              {workspaces.data?.ca_workspace.available && (
                <a href="/app" className="text-sm underline underline-offset-4">CA workspace</a>
              )}
            </div>
            <form action="/users/log_out" method="post">
              <Input type="hidden" name="_method" value="delete" />
              <Input
                type="hidden"
                name="_csrf_token"
                value={
                  document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
                }
              />
              <Button type="submit" variant="ghost" size="sm">
                Sign out
              </Button>
            </form>
          </div>
          <nav
            aria-label="Business"
            className={`mx-auto flex gap-6 overflow-x-auto px-4 sm:px-8 ${editingInvoice ? "max-w-[1440px]" : "max-w-6xl"}`}
          >
            {(
              [
                ["/business/$businessId/invoices", "Invoices"],
                ["/business/$businessId/quotations", "Quotations"],
                ["/business/$businessId/customers", "Customers"],
                ["/business/$businessId/services", "Items"],
                ["/business/$businessId/settings", "Settings"],
              ] as const
            ).map(([path, title]) => (
              <Link
                key={path}
                to={path}
                params={{ businessId }}
                activeOptions={{ includeSearch: false }}
                className="border-b-2 py-3 text-sm whitespace-nowrap"
                activeProps={{ className: "border-foreground font-medium" }}
                inactiveProps={{ className: "border-transparent text-muted-foreground" }}
              >
                {title}
              </Link>
            ))}
          </nav>
        </header>
        <main
          className={`mx-auto px-4 py-6 sm:px-8 ${editingInvoice ? "max-w-[1440px]" : "max-w-6xl"}`}
        >
          <Outlet key={businessId} />
        </main>
      </div>
    </Workspace.Provider>
  );
}

// Bigcapital estimate reference: EstimateFormHeaderFields.tsx (expiry),
// EstimatesLanding/components.tsx (accept/decline and convert-to-invoice actions).
function quotationLabel(invoice: BusinessInvoice) {
  if (invoice.converted_invoice_id) return "Converted";
  if (invoice.status === "draft") return "Draft";
  if (invoice.status === "awaiting_po") return "Awaiting PO";
  if (invoice.status === "accepted") return "Accepted";
  if (invoice.status === "declined") return "Declined";
  return "Ready";
}

function businessDocumentDate(value: string) {
  if (!value) return "—";
  const [year, month, day] = value.split("-").map(Number);
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return `${String(day).padStart(2, "0")} ${months[month - 1]} ${year}`;
}

function financialYearFor(value: string) {
  const [year, month] = value.split("-").map(Number);
  return month >= 4 ? year : year - 1;
}

function financialYearLabel(year: number) {
  return `${year}–${String(year + 1).slice(-2)}`;
}

export function BusinessInvoices({ mode = "invoice" }: { mode?: "invoice" | "quotation" }) {
  const businessId = useBusinessId();
  const data = useBusiness();
  const quotation = mode === "quotation";
  const documents = data.invoices.filter(
    (invoice) => (invoice.document_type === "quotation") === quotation,
  );
  const [search, setSearch] = useState("");
  const [financialYear, setFinancialYear] = useState("all");
  const [status, setStatus] = useState("all");
  const financialYears = Array.from(
    new Set(documents.map((document) => financialYearFor(document.invoice_date))),
  ).sort((left, right) => right - left);
  const normalizedSearch = search.trim().toLocaleLowerCase();
  const filteredDocuments = documents.filter((document) => {
    const customer =
      document.snapshot?.customer?.name ??
      data.customers.find((candidate) => candidate.id === Number(document.customer_id))?.name ??
      "";
    const matchesSearch =
      !normalizedSearch ||
      [
        document.number,
        customer,
        document.subject,
        document.purchase_order_number,
        document.delivery_address,
        document.snapshot?.shipping_name,
        document.snapshot?.delivery_address,
      ].some((value) => value?.toLocaleLowerCase().includes(normalizedSearch));
    const matchesFinancialYear =
      financialYear === "all" || financialYearFor(document.invoice_date) === Number(financialYear);
    const documentStatus = quotation
      ? quotationLabel(document).toLocaleLowerCase()
      : document.status;
    return matchesSearch && matchesFinancialYear && (status === "all" || documentStatus === status);
  });
  const filtersActive = search !== "" || financialYear !== "all" || status !== "all";

  function clearFilters() {
    setSearch("");
    setFinancialYear("all");
    setStatus("all");
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">{quotation ? "Quotations" : "Invoices"}</h1>
          <p className="mt-2 text-sm text-muted-foreground">
            {quotation
              ? "Prepare an offer, record the response, then turn accepted work into an invoice."
              : "Issued invoices are shared with your CA."}
          </p>
        </div>
        <Button
          nativeButton={false}
          role="link"
          render={<Link to={quotation ? "/business/$businessId/quotations/new" : "/business/$businessId/invoices/new"} params={{ businessId }} />}
        >
          <Plus />
          {quotation ? "New quotation" : "New invoice"}
        </Button>
      </div>
      {documents.length > 0 && (
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
          <Input
            aria-label={`Search ${quotation ? "quotations" : "invoices"}`}
            className="sm:max-w-sm"
            placeholder={`Search ${quotation ? "quotations" : "invoices"}`}
            type="search"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
          <SelectField
            aria-label="Financial year"
            className="w-full sm:w-40"
            value={financialYear}
            onValueChange={setFinancialYear}
          >
            <SelectFieldOption value="all">All financial years</SelectFieldOption>
            {financialYears.map((year) => (
              <SelectFieldOption key={year} value={year}>
                {financialYearLabel(year)}
              </SelectFieldOption>
            ))}
          </SelectField>
          <SelectField
            aria-label="Status"
            className="w-full sm:w-36"
            value={status}
            onValueChange={setStatus}
          >
            <SelectFieldOption value="all">All statuses</SelectFieldOption>
            {quotation ? (
              <>
                <SelectFieldOption value="draft">Draft</SelectFieldOption>
                <SelectFieldOption value="ready">Ready</SelectFieldOption>
                <SelectFieldOption value="awaiting po">Awaiting PO</SelectFieldOption>
                <SelectFieldOption value="accepted">Accepted</SelectFieldOption>
                <SelectFieldOption value="declined">Declined</SelectFieldOption>
                <SelectFieldOption value="converted">Converted</SelectFieldOption>
              </>
            ) : (
              <>
                <SelectFieldOption value="draft">Draft</SelectFieldOption>
                <SelectFieldOption value="issued">Issued</SelectFieldOption>
                <SelectFieldOption value="cancelled">Cancelled</SelectFieldOption>
              </>
            )}
          </SelectField>
          {filtersActive && (
            <Button className="self-start sm:self-auto" variant="ghost" onClick={clearFilters}>
              Clear filters
            </Button>
          )}
        </div>
      )}
      <div className="overflow-hidden rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>{quotation ? "Quotation" : "Invoice"}</TableHead>
              <TableHead>Customer</TableHead>
              <TableHead>Date</TableHead>
              {quotation && <TableHead>Valid until</TableHead>}
              <TableHead>Status</TableHead>
              <TableHead className="text-right">Total</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {filteredDocuments.map((invoice) => (
              <RecordTableRow key={invoice.id}>
                <TableCell>
                  <RecordTableLink
                    className="font-medium underline-offset-4 hover:underline"
                    to={
                      quotation
                        ? "/business/$businessId/quotations/$invoiceId"
                        : "/business/$businessId/invoices/$invoiceId"
                    }
                    params={{ businessId, invoiceId: String(invoice.id) }}
                  >
                    {invoice.number || "Draft"}
                    {invoice.document_type === "credit_note" ? " · Credit note" : ""}
                  </RecordTableLink>
                </TableCell>
                <TableCell>
                  {invoice.snapshot?.customer?.name ??
                    data.customers.find((customer) => customer.id === Number(invoice.customer_id))
                      ?.name ??
                    "Customer not selected"}
                </TableCell>
                <TableCell>{businessDocumentDate(invoice.invoice_date)}</TableCell>
                {quotation && <TableCell>{businessDocumentDate(invoice.valid_until || "")}</TableCell>}
                <TableCell>
                  <Badge
                    variant={
                      invoice.status === "cancelled"
                        ? "destructive"
                        : invoice.status !== "draft"
                          ? "secondary"
                          : "outline"
                    }
                  >
                    {quotation
                      ? quotationLabel(invoice)
                      : invoice.status === "cancelled"
                        ? "Cancelled"
                        : invoice.status === "issued"
                          ? "Issued"
                      : "Draft"}
                  </Badge>
                  {quotation && invoice.sent_on && (
                    <p className="mt-1 text-xs text-muted-foreground">
                      Sent {businessDocumentDate(invoice.sent_on)}
                    </p>
                  )}
                  {quotation && invoice.purchase_order_number && (
                    <p className="mt-1 text-xs text-muted-foreground">
                      PO {invoice.purchase_order_number}
                    </p>
                  )}
                </TableCell>
                <TableCell className="text-right tabular-nums">
                  {invoice.totals && Number.isFinite(invoice.totals.total_paise)
                    ? money(invoice.totals.total_paise)
                    : "—"}
                </TableCell>
              </RecordTableRow>
            ))}
            {documents.length === 0 && (
              <TableRow>
                <TableCell colSpan={quotation ? 6 : 5} className="py-16 text-center">
                  <p className="font-medium">
                    {quotation
                      ? "Your first quotation starts here"
                      : "Your first invoice starts here"}
                  </p>
                  <p className="mt-2 text-sm text-muted-foreground">
                    {quotation
                      ? "Create a draft, check the details, then finalize and download the PDF."
                      : "Create a draft, check the details, then issue it and download the PDF."}
                  </p>
                </TableCell>
              </TableRow>
            )}
            {documents.length > 0 && filteredDocuments.length === 0 && (
              <TableRow>
                <TableCell colSpan={quotation ? 6 : 5} className="py-16 text-center">
                  <p className="font-medium">No matching {quotation ? "quotations" : "invoices"}</p>
                  <p className="mt-2 text-sm text-muted-foreground">
                    Try another search or clear the filters.
                  </p>
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

export function BusinessCustomers() {
  const businessId = useBusinessId();
  const queryKey = businessQueryKey(businessId);
  const data = useBusiness();
  const cache = useQueryClient();
  const navigate = useNavigate();
  const empty = { name: "", gstin: "", address: "", state_code: "" };
  const [form, setForm] = useState(empty);
  const [show, setShow] = useState(false);
  const customerSave = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: (customer: typeof empty) =>
      businessRequest("createBusinessCustomer", {
        businessId,
        body: { customer },
      }),
    onSuccess: () => cache.invalidateQueries({ queryKey }),
  });
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (customerSave.isPending) return;
    try {
      const result = await customerSave.mutateAsync(form);
      setShow(false);
      await navigate({
        to: "/business/$businessId/customers/$customerId",
        params: { businessId, customerId: String(result.customer.id) },
      });
    } catch {
      // The mutation keeps its error visible in the dialog.
    }
  }
  function add() {
    setForm(empty);
    customerSave.reset();
    setShow(true);
  }
  return (
    <div className="mx-auto max-w-4xl space-y-6">
      <div className="flex items-start justify-between gap-4">
        <div className="space-y-1">
          <h1 className="text-2xl font-semibold">Customers</h1>
          <p className="text-sm text-muted-foreground">
            {data.customers.length === 1 ? "1 customer" : `${data.customers.length} customers`}
          </p>
        </div>
        <Button onClick={add}>
          <Plus /> Add customer
        </Button>
      </div>
      <Dialog open={show} onOpenChange={(next) => !customerSave.isPending && setShow(next)}>
        <DialogContent className="sm:max-w-lg">
          <div className="space-y-1">
            <DialogTitle>Add customer</DialogTitle>
            <DialogDescription>
              Start with the billing details. Add hospital locations after saving.
            </DialogDescription>
          </div>
          <form id="business-customer-form" onSubmit={submit} className="space-y-4">
            <Errors error={customerSave.error} />
            <fieldset disabled={customerSave.isPending} className="space-y-4">
              <Field label="Customer name" id="customer-name">
                <Input
                  id="customer-name"
                  required
                  value={form.name}
                  onChange={(event) => setForm({ ...form, name: event.target.value })}
                />
              </Field>
              <Field label="GSTIN (optional)" id="customer-gstin">
                <Input
                  id="customer-gstin"
                  value={form.gstin}
                  maxLength={15}
                  onChange={(event) => setForm({ ...form, gstin: event.target.value.toUpperCase() })}
                />
              </Field>
              <Field label="Primary billing address" id="customer-address">
                <Textarea
                  id="customer-address"
                  required
                  rows={3}
                  value={form.address}
                  onChange={(event) => setForm({ ...form, address: event.target.value })}
                />
              </Field>
              <Field label="State" id="customer-state">
                <StateSelect
                  id="customer-state"
                  value={form.state_code}
                  onChange={(value) => setForm({ ...form, state_code: value })}
                />
              </Field>
              <div className="flex justify-end gap-2 pt-2">
                <Button type="button" variant="outline" onClick={() => setShow(false)}>Cancel</Button>
                <Button type="submit">{customerSave.isPending ? "Saving…" : "Save customer"}</Button>
              </div>
            </fieldset>
          </form>
        </DialogContent>
      </Dialog>
      <div className="overflow-hidden rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead className="w-1/2 pl-4">Customer</TableHead>
              <TableHead>GSTIN</TableHead>
              <TableHead>Service locations</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {data.customers.map((customer) => (
                <RecordTableRow key={customer.id}>
                  <TableCell className="pl-4 font-medium">
                    <RecordTableLink
                      to="/business/$businessId/customers/$customerId"
                      params={{ businessId, customerId: String(customer.id) }}
                      className="hover:underline hover:underline-offset-4"
                    >
                      {customer.name}
                    </RecordTableLink>
                  </TableCell>
                  <TableCell className={customer.gstin ? "" : "text-muted-foreground"}>
                    {customer.gstin || "Unregistered"}
                  </TableCell>
                  <TableCell className="text-muted-foreground">
                    {data.customer_addresses.filter((address) =>
                      address.customer_id === customer.id &&
                      address.usage !== "billing" &&
                      !address.is_primary_billing,
                    ).length}
                  </TableCell>
                </RecordTableRow>
            ))}
            {data.customers.length === 0 && (
              <TableRow>
                <TableCell colSpan={3} className="py-12 text-center text-muted-foreground">
                  Add a customer to make your first invoice.
                </TableCell>
              </TableRow>
            )}
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

export function BusinessCustomerDetail() {
  const businessId = useBusinessId();
  const { customerId } = useParams({ strict: false }) as { customerId: string };
  const data = useBusiness();
  const cache = useQueryClient();
  const customer = data.customers.find((entry) => entry.id === Number(customerId));
  const [search, setSearch] = useState("");
  const [page, setPage] = useState(0);
  const [nameOpen, setNameOpen] = useState(false);
  const [name, setName] = useState("");
  const [addressOpen, setAddressOpen] = useState(false);
  const [addressPurpose, setAddressPurpose] = useState<"billing" | "location">("location");
  const [editingAddress, setEditingAddress] = useState<BusinessCustomerAddress | null>(null);
  const [addressDraft, setAddressDraft] = useState<Omit<BusinessCustomerAddress, "id" | "customer_id">>({
    label: "", address: "", state_code: "", gstin: null, usage: "shipping",
    is_primary_billing: false, is_primary_shipping: false,
  });
  const nameSave = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: (input: { id: number; name: string; address: string; state_code: string; gstin: string }) =>
      businessRequest("updateBusinessCustomer", {
        businessId,
        id: input.id,
        body: { customer: { name: input.name, address: input.address, state_code: input.state_code, gstin: input.gstin } },
      }),
    onSuccess: () => cache.invalidateQueries({ queryKey: businessQueryKey(businessId) }),
  });
  const addressSave = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: (input: { id: number | null; address: typeof addressDraft }) =>
      businessRequest(input.id ? "updateBusinessCustomerAddress" : "createBusinessCustomerAddress", {
        businessId,
        customer_id: Number(customerId),
        id: input.id ?? undefined,
        body: { address: input.address },
      }),
    onSuccess: () => cache.invalidateQueries({ queryKey: businessQueryKey(businessId) }),
  });

  async function submitName(event: FormEvent) {
    event.preventDefault();
    if (!customer || nameSave.isPending) return;
    try {
      await nameSave.mutateAsync({
        id: customer.id, name, address: customer.address,
        state_code: customer.state_code, gstin: customer.gstin ?? "",
      });
      setNameOpen(false);
    } catch {
      // The mutation keeps its error visible in the dialog.
    }
  }

  function openAddress(address: BusinessCustomerAddress | null, purpose: "billing" | "location") {
    setEditingAddress(address);
    setAddressPurpose(purpose);
    setAddressDraft(address ? {
      label: address.label,
      address: address.address,
      state_code: address.state_code,
      gstin: address.gstin,
      usage: address.usage,
      is_primary_billing: address.is_primary_billing,
      is_primary_shipping: address.is_primary_shipping,
    } : {
      label: "", address: "", state_code: "", gstin: null,
      usage: purpose === "billing" ? "billing" : "shipping",
      is_primary_billing: false, is_primary_shipping: false,
    });
    addressSave.reset();
    setAddressOpen(true);
  }

  async function submitAddress(event: FormEvent) {
    event.preventDefault();
    if (addressSave.isPending) return;
    try {
      await addressSave.mutateAsync({ id: editingAddress?.id ?? null, address: addressDraft });
      setAddressOpen(false);
    } catch {
      // The mutation keeps its error visible in the dialog.
    }
  }

  if (!customer) {
    return <div className="mx-auto max-w-4xl space-y-4">
      <h1 className="text-2xl font-semibold">Customer not found</h1>
      <Link to="/business/$businessId/customers" params={{ businessId }} className="text-sm underline underline-offset-4">Back to customers</Link>
    </div>;
  }

  const addresses: BusinessCustomerAddress[] = data.customer_addresses.filter(
    (address) => address.customer_id === customer.id,
  );
  const primary = addresses.find((address) => address.is_primary_billing);
  const locations = addresses.filter(
    (address) => address.id !== primary?.id && address.usage !== "billing",
  );
  const stateName = (code: string) => data.states.find((state) => state.code === code)?.name ?? code;
  const billingAddresses = addresses.filter(
    (address) => address.id !== primary?.id && address.usage !== "shipping",
  );
  const query = search.trim().toLocaleLowerCase();
  const filteredLocations = query
    ? locations.filter((address) => [address.label, address.address, stateName(address.state_code), address.gstin ?? ""]
      .some((value) => value.toLocaleLowerCase().includes(query)))
    : locations;
  const pageSize = 25;
  const visibleLocations = filteredLocations.slice(page * pageSize, (page + 1) * pageSize);

  return <div className="mx-auto max-w-4xl space-y-8">
    <div className="space-y-3">
      <Link to="/business/$businessId/customers" params={{ businessId }} className="inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
        <ArrowLeft className="size-4" /> Customers
      </Link>
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">{customer.name}</h1>
          <p className="mt-1 text-sm text-muted-foreground">{customer.gstin || "Unregistered customer"}</p>
        </div>
        <Button variant="outline" onClick={() => { setName(customer.name); nameSave.reset(); setNameOpen(true); }}>
          Edit name
        </Button>
      </div>
    </div>

    <section className="space-y-3">
      <div className="flex items-center justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold">Billing addresses</h2>
          <p className="text-sm text-muted-foreground">Used when preparing invoices for this customer.</p>
        </div>
        <Button variant="outline" size="sm" onClick={() => openAddress(null, "billing")}><Plus /> Add billing address</Button>
      </div>
      <div className="divide-y rounded-lg border text-sm">
        <div className="flex items-start justify-between gap-4 p-4">
          <div className="min-w-0">
            <div className="flex items-center gap-2">
              <p className="font-medium">{primary?.label ?? "Primary address"}</p>
              <Badge variant="secondary">Default billing</Badge>
            </div>
            <p className="mt-2 whitespace-pre-wrap">{primary?.address ?? customer.address}</p>
            <p className="mt-1 text-muted-foreground">{stateName(primary?.state_code ?? customer.state_code)}{(primary?.gstin ?? customer.gstin) ? ` · GSTIN ${primary?.gstin ?? customer.gstin}` : ""}</p>
          </div>
          {primary && <Button variant="ghost" size="sm" onClick={() => openAddress(primary, "billing")}>Edit</Button>}
        </div>
        {billingAddresses.map((address) => <div key={address.id} className="flex items-start justify-between gap-4 p-4">
          <div className="min-w-0">
            <p className="font-medium">{address.label}</p>
            <p className="mt-1 whitespace-pre-wrap">{address.address}</p>
            <p className="mt-1 text-muted-foreground">{stateName(address.state_code)}{address.gstin ? ` · GSTIN ${address.gstin}` : ""}</p>
          </div>
          <Button variant="ghost" size="sm" onClick={() => openAddress(address, "billing")}>Edit</Button>
        </div>)}
      </div>
    </section>

    <section className="space-y-3">
      <div className="flex items-center justify-between gap-4">
        <div>
          <h2 className="text-base font-semibold">Service locations</h2>
          <p className="text-sm text-muted-foreground">{locations.length} saved ship-to {locations.length === 1 ? "location" : "locations"} for invoices.</p>
        </div>
        <Button onClick={() => openAddress(null, "location")}><Plus /> Add location</Button>
      </div>
      <Input
        aria-label="Search service locations"
        placeholder="Search hospitals, addresses, states, or GSTINs"
        value={search}
        onChange={(event) => { setSearch(event.target.value); setPage(0); }}
        className="max-w-md"
      />
      <div className="overflow-hidden rounded-lg border">
        <Table>
          <TableHeader><TableRow><TableHead className="pl-4">Location</TableHead><TableHead>Address</TableHead><TableHead>State</TableHead><TableHead className="w-16 pr-4"><span className="sr-only">Actions</span></TableHead></TableRow></TableHeader>
          <TableBody>
            {visibleLocations.map((address) => <TableRow key={address.id}>
              <TableCell className="pl-4 font-medium">{address.label}</TableCell>
              <TableCell className="max-w-96 whitespace-normal">
                <span className="line-clamp-2">{address.address}</span>
                {address.gstin && <span className="text-xs text-muted-foreground">GSTIN {address.gstin}</span>}
              </TableCell>
              <TableCell>{stateName(address.state_code)}</TableCell>
              <TableCell className="pr-4 text-right"><Button variant="ghost" size="sm" onClick={() => openAddress(address, "location")}>Edit<span className="sr-only"> {address.label}</span></Button></TableCell>
            </TableRow>)}
            {filteredLocations.length === 0 && <TableRow><TableCell colSpan={4} className="py-10 text-center text-muted-foreground">{query ? "No locations match your search." : "No service locations yet. Add the first hospital or ship-to site."}</TableCell></TableRow>}
          </TableBody>
        </Table>
      </div>
      {filteredLocations.length > pageSize && <div className="flex items-center justify-between text-sm text-muted-foreground">
        <span>Showing {page * pageSize + 1}–{Math.min((page + 1) * pageSize, filteredLocations.length)} of {filteredLocations.length}</span>
        <div className="flex gap-2">
          <Button variant="outline" size="sm" disabled={page === 0} onClick={() => setPage((current) => current - 1)}>Previous</Button>
          <Button variant="outline" size="sm" disabled={(page + 1) * pageSize >= filteredLocations.length} onClick={() => setPage((current) => current + 1)}>Next</Button>
        </div>
      </div>}
    </section>

    <Dialog open={nameOpen} onOpenChange={(next) => !nameSave.isPending && setNameOpen(next)}>
      <DialogContent className="sm:max-w-md">
        <DialogTitle>Edit customer name</DialogTitle>
        <form onSubmit={submitName} className="space-y-4">
          <Errors error={nameSave.error} />
          <fieldset disabled={nameSave.isPending} className="space-y-4">
            <Field label="Customer name" id="edit-customer-name">
              <Input id="edit-customer-name" required value={name} onChange={(event) => setName(event.target.value)} />
            </Field>
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" onClick={() => setNameOpen(false)}>Cancel</Button>
              <Button type="submit">{nameSave.isPending ? "Saving…" : "Save name"}</Button>
            </div>
          </fieldset>
        </form>
      </DialogContent>
    </Dialog>

    <Dialog open={addressOpen} onOpenChange={(next) => !addressSave.isPending && setAddressOpen(next)}>
      <DialogContent className="sm:max-w-lg">
        <div className="space-y-1">
          <DialogTitle>{editingAddress ? "Edit" : "Add"} {addressPurpose === "billing" ? "billing address" : "service location"}</DialogTitle>
          <DialogDescription>
            {addressPurpose === "billing"
              ? "Save the address and GST details used when billing this customer."
              : "Save a hospital or other ship-to site for future invoices."}
          </DialogDescription>
        </div>
        <form onSubmit={submitAddress} className="space-y-4">
          <Errors error={addressSave.error} />
          <fieldset disabled={addressSave.isPending} className="space-y-4">
            <Field label={addressPurpose === "billing" ? "Address label" : "Hospital or location name"} id="saved-address-label">
              <Input id="saved-address-label" required maxLength={100} value={addressDraft.label} onChange={(event) => setAddressDraft({ ...addressDraft, label: event.target.value })} />
            </Field>
            <Field label="Address" id="saved-address-text">
              <Textarea id="saved-address-text" required maxLength={2000} rows={3} value={addressDraft.address} onChange={(event) => setAddressDraft({ ...addressDraft, address: event.target.value })} />
            </Field>
            <Field label="State" id="saved-address-state">
              <StateSelect id="saved-address-state" value={addressDraft.state_code} onChange={(state_code) => setAddressDraft({ ...addressDraft, state_code })} />
            </Field>
            <Field label="GSTIN (optional)" id="saved-address-gstin">
              <Input id="saved-address-gstin" maxLength={15} value={addressDraft.gstin ?? ""} onChange={(event) => setAddressDraft({ ...addressDraft, gstin: event.target.value.toUpperCase() })} />
            </Field>
            {addressPurpose === "billing" && !editingAddress?.is_primary_billing && <label className="flex items-center gap-2 text-sm">
              <Checkbox
                checked={addressDraft.is_primary_billing}
                onCheckedChange={(checked) => setAddressDraft({ ...addressDraft, is_primary_billing: Boolean(checked) })}
              />
              Make this the default billing address
            </label>}
            <div className="flex justify-end gap-2 pt-1">
              <Button type="button" variant="outline" onClick={() => setAddressOpen(false)}>Cancel</Button>
              <Button type="submit">{addressSave.isPending ? "Saving…" : editingAddress ? "Save changes" : "Save address"}</Button>
            </div>
          </fieldset>
        </form>
      </DialogContent>
    </Dialog>
  </div>;
}

export function BusinessServices() {
  const data = useBusiness();
  return <ServicesPage services={data.services ?? []} />;
}

export function BusinessSettings() {
  const businessId = useBusinessId();
  const { section } = useParams({ strict: false }) as { section: string };
  const queryKey = businessQueryKey(businessId);
  const data = useBusiness();
  const cache = useQueryClient();
  const [form, setForm] = useState<
    import("@/lib/generated/workspace").components["schemas"]["BusinessProfileInput"]
  >(() => ({
    legal_name: data.profile?.legal_name ?? data.business.name,
    address: data.profile?.address ?? "",
    state_code: data.profile?.state_code ?? data.business.gstin?.slice(0, 2) ?? "",
    phone: data.profile?.phone ?? "",
    email: data.profile?.email ?? "",
    e_invoice_not_applicable: data.profile?.e_invoice_not_applicable ?? false,
    domestic_services_only: data.profile?.domestic_services_only ?? false,
    domestic_goods_and_services_only: data.profile?.domestic_goods_and_services_only ?? false,
  }));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const [saved, setSaved] = useState(false);
  const [assetVersion, setAssetVersion] = useState(0);
  const [numbering, setNumbering] = useState(data.quotation_numbering);
  const [numberingInput, setNumberingInput] = useState(data.quotation_numbering.next_quotation_number);
  const [invoiceNumbering, setInvoiceNumbering] = useState(data.invoice_numbering);
  useEffect(() => {
    setSaved(false);
    setError(null);
  }, [section]);
  const financialYearShort = `${String(numbering.financial_year).slice(-2)}${String(numbering.financial_year + 1).slice(-2)}`;
  const settingsSections = [
    ["business", "Business profile"],
    ["document-numbers", "Document numbers"],
    ["branding", "Branding"],
  ] as const;

  async function changeAsset(kind: "logo" | "signature", file?: File) {
    if (!file || busy) return;
    setError(null);
    if (file.size > 512_000 || !["image/png", "image/jpeg"].includes(file.type)) {
      setError(new Error("Choose a PNG or JPEG smaller than 500 KB."));
      return;
    }
    setBusy(true);
    try {
      await uploadBusinessBrandAsset(businessId, kind, file);
      await cache.invalidateQueries({ queryKey });
      setAssetVersion((current) => current + 1);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }

  async function removeAsset(kind: "logo" | "signature") {
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await businessRequest("removeBusinessBrandAsset", { businessId, kind });
      await cache.invalidateQueries({ queryKey });
      setAssetVersion((current) => current + 1);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }

  async function saveNumbering() {
    if (busy || !numbering.editable) return;
    setBusy(true);
    setError(null);
    try {
      const result = await businessRequest("configureBusinessQuotationNumbering", {
        businessId,
        body: { numbering: { next_quotation_number: numberingInput } },
      });
      setNumbering(result.quotation_numbering);
      setNumberingInput(result.quotation_numbering.next_quotation_number);
      await cache.invalidateQueries({ queryKey });
      setSaved(true);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }
  async function saveInvoiceNumbering() {
    if (busy || !invoiceNumbering.editable) return;
    setBusy(true);
    setError(null);
    try {
      const result = await businessRequest("configureBusinessInvoiceNumbering", {
        businessId,
        body: {
          numbering: { style: invoiceNumbering.style, next_number: invoiceNumbering.next_number },
        },
      });
      setInvoiceNumbering(result.invoice_numbering);
      await cache.invalidateQueries({ queryKey });
      setSaved(true);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    setSaved(false);
    try {
      await businessRequest("updateBusinessProfile", { businessId, body: { profile: form } });
      await cache.invalidateQueries({ queryKey });
      setSaved(true);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }
  if (!settingsSections.some(([key]) => key === section))
    return <Navigate to="/business/$businessId/settings/$section" params={{ businessId, section: "business" }} replace />;
  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-semibold">Settings</h1>
        <p className="mt-2 text-sm text-muted-foreground">Manage your business and document settings.</p>
      </div>
      <div className="grid gap-8 md:grid-cols-[180px_minmax(0,1fr)] md:gap-10">
        <nav aria-label="Business settings" className="flex gap-1 overflow-x-auto md:flex-col md:border-r md:pr-5">
          {settingsSections.map(([key, label]) => (
            <Link
              key={key}
              to="/business/$businessId/settings/$section"
              params={{ businessId, section: key }}
              className="rounded-md px-3 py-2 text-sm whitespace-nowrap text-muted-foreground hover:bg-muted hover:text-foreground"
              activeOptions={{ exact: true }}
              activeProps={{ className: "bg-muted font-medium text-foreground" }}
            >
              {label}
            </Link>
          ))}
        </nav>
        <div className="min-w-0 max-w-2xl space-y-6">
      <Errors error={error} />
      {saved && (
        <p role="status" className="text-sm">
          Settings saved.
        </p>
      )}
      {section === "business" && (
        <form onSubmit={submit} className="space-y-6">
          <div>
            <h2 className="text-xl font-semibold">
              {data.profile?.address ? "Business profile" : "Finish setting up your business"}
            </h2>
            <p className="mt-1 text-sm text-muted-foreground">
              Add the details that appear on your quotations and invoices.
            </p>
          </div>
          <fieldset disabled={busy} className="space-y-6">
            <div className="grid gap-5 sm:grid-cols-2">
              <Field label="Legal name" id="business-name">
                <Input
                  id="business-name"
                  required
                  value={form.legal_name ?? ""}
                  onChange={(e) => {
                    setSaved(false);
                    setForm({ ...form, legal_name: e.target.value });
                  }}
                />
              </Field>
              <Field label="GSTIN" id="business-gstin">
                <Input id="business-gstin" readOnly value={data.business.gstin ?? ""} />
              </Field>
              <div className="sm:col-span-2">
                <Field label="Business address" id="business-address">
                  <Input
                    id="business-address"
                    required
                    value={form.address ?? ""}
                    onChange={(e) => {
                      setSaved(false);
                      setForm({ ...form, address: e.target.value });
                    }}
                  />
                </Field>
              </div>
              <Field label="Phone (optional)" id="business-phone">
                <Input
                  id="business-phone"
                  type="tel"
                  maxLength={40}
                  value={form.phone ?? ""}
                  onChange={(e) => setForm({ ...form, phone: e.target.value })}
                />
              </Field>
              <Field label="Email (optional)" id="business-email">
                <Input
                  id="business-email"
                  type="email"
                  maxLength={254}
                  value={form.email ?? ""}
                  onChange={(e) => setForm({ ...form, email: e.target.value })}
                />
              </Field>
              <Field label="State" id="business-state">
                <StateSelect
                  id="business-state"
                  value={form.state_code ?? ""}
                  onChange={(value) => {
                    setSaved(false);
                    setForm({ ...form, state_code: value });
                  }}
                />
              </Field>
            </div>
            <Button type="submit">{busy ? "Saving…" : "Save business details"}</Button>
          </fieldset>
        </form>
      )}
      {section === "document-numbers" && (
        <div className="space-y-8">
          <div>
            <h2 className="text-xl font-semibold">Document numbers</h2>
            <p className="mt-1 text-sm text-muted-foreground">Choose how invoices and quotations are numbered.</p>
            <p className="mt-4 text-sm font-medium">{numbering.financial_year}–{String(numbering.financial_year + 1).slice(-2)} financial year</p>
          </div>
          <section className="space-y-4" aria-label="Invoice numbering">
            <div>
              <h3 className="font-medium">Invoice numbers</h3>
            </div>
            {invoiceNumbering.editable ? (
              <>
            <Field label="Number format" id="business-invoice-style">
              <SelectField
                id="business-invoice-style"
                disabled={!invoiceNumbering.editable || busy}
                value={invoiceNumbering.style}
                onValueChange={(nextValue) =>
                  setInvoiceNumbering({
                    ...invoiceNumbering,
                    style: nextValue as typeof invoiceNumbering.style,
                  })
                }
              >
                <SelectFieldOption value="nila">
                  INV/{financialYearShort}/0001
                </SelectFieldOption>
                <SelectFieldOption value="serial_fy">
                  1/{invoiceNumbering.financial_year}-{String(invoiceNumbering.financial_year + 1).slice(-2)}
                </SelectFieldOption>
              </SelectField>
            </Field>
            <Field label="Starting number" id="business-invoice-next">
              <Input
                id="business-invoice-next"
                type="number"
                min={1}
                max={999999}
                disabled={!invoiceNumbering.editable || busy}
                value={invoiceNumbering.next_number}
                onChange={(e) =>
                  setInvoiceNumbering({ ...invoiceNumbering, next_number: Number(e.target.value) })
                }
              />
            </Field>
            <p className="text-sm">First invoice: <strong>{invoiceNumber(invoiceNumbering)}</strong></p>
            <Button
              type="button"
              variant="outline"
              disabled={!invoiceNumbering.editable || busy}
              onClick={saveInvoiceNumbering}
            >
              Save invoice numbering
            </Button>
              </>
            ) : (
              <div className="space-y-2 text-sm">
                <p>Format: <strong>{invoiceNumber({ ...invoiceNumbering, next_number: 1 })}</strong></p>
                <p>Next invoice: <strong>{invoiceNumber(invoiceNumbering)}</strong></p>
                <Badge variant="secondary">Locked</Badge>
                <p className="text-muted-foreground">Numbering locked after the first invoice was issued.</p>
              </div>
            )}
          </section>
          <section className="space-y-4 border-t pt-5" aria-label="Quotation numbering">
            <div>
              <h3 className="font-medium">Quotation numbers</h3>
            </div>
            <Field label="Next quotation number" id="business-quote-next">
              <Input id="business-quote-next" maxLength={60} value={numberingInput} onChange={(event) => { setSaved(false); setNumberingInput(event.target.value); }} disabled={busy} />
            </Field>
            <QuotationNumberPreview value={numberingInput} financialYear={numbering.financial_year} />
            <Button type="button" variant="outline" disabled={busy || !nextQuotationNumbers(numberingInput, numbering.financial_year)} onClick={saveNumbering}>Save quotation numbering</Button>
          </section>
        </div>
      )}
      {section === "branding" && (
        <section className="space-y-5" aria-label="Business branding">
            <div>
              <h2 className="text-xl font-semibold">Branding</h2>
              <p className="mt-1 text-sm text-muted-foreground">Add a logo or signature to new quotations and invoices.</p>
            </div>
            {(["logo", "signature"] as const).map((kind) => {
              const present =
                kind === "logo" ? data.profile?.has_logo : data.profile?.has_signature;
              return (
                <div key={kind} className="space-y-2">
                  <label className="block text-sm font-medium" htmlFor={`business-${kind}`}>
                    {kind === "logo" ? "Logo" : "Signature or stamp"} (optional)
                  </label>
                  {present && (
                    <img
                      src={`/api/business/${businessId}/profile/assets/${kind}?v=${assetVersion}`}
                      alt={kind === "logo" ? "Current business logo" : "Current signature or stamp"}
                      className="max-h-24 max-w-48 object-contain"
                    />
                  )}
                  <Input
                    id={`business-${kind}`}
                    type="file"
                    accept="image/png,image/jpeg"
                    disabled={busy}
                    onChange={(e) => {
                      void changeAsset(kind, e.target.files?.[0]);
                      e.target.value = "";
                    }}
                  />
                  {present && (
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      disabled={busy}
                      onClick={() => removeAsset(kind)}
                    >
                      Remove {kind === "logo" ? "logo" : "signature"}
                    </Button>
                  )}
                </div>
              );
            })}
            <p className="text-sm text-muted-foreground">
              PNG or JPEG, up to 500 KB each.
            </p>
          </section>
      )}
        </div>
      </div>
    </div>
  );
}

export function BusinessInvoiceEditor({ mode = "invoice" }: { mode?: "invoice" | "quotation" }) {
  const businessId = useBusinessId();
  const { invoiceId } = useParams({ strict: false });
  const params = useSearch({ strict: false });
  const originalId = mode === "invoice" ? params.credit_for : null;
  const query = useQuery({
    queryKey: ["business-invoice", businessId, invoiceId ?? originalId],
    queryFn: ({ signal }) =>
      businessRequest("getBusinessInvoice", { businessId, id: invoiceId ?? originalId!, signal }),
    enabled: Boolean(invoiceId ?? originalId),
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry,
  });
  const linkedOriginalId =
    invoiceId && query.data?.invoice.document_type === "credit_note"
      ? query.data.invoice.original_invoice_id
      : null;
  const linkedOriginal = useQuery({
    queryKey: ["business-original-invoice", businessId, linkedOriginalId],
    queryFn: ({ signal }) =>
      businessRequest("getBusinessInvoice", { businessId, id: linkedOriginalId!, signal }),
    enabled: Boolean(linkedOriginalId),
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry,
  });
  if (linkedOriginalId && linkedOriginal.isError)
    return (
      <div className="space-y-4">
        <Errors error={linkedOriginal.error} />
        <Button onClick={() => linkedOriginal.refetch()}>Try again</Button>
      </div>
    );
  if (linkedOriginalId && (linkedOriginal.isPending || linkedOriginal.isFetching))
    return <p role="status">Loading original invoice…</p>;
  if ((invoiceId || originalId) && (query.isPending || query.isFetching))
    return <p role="status">Loading invoice…</p>;
  if (query.isError)
    return (
      <div className="space-y-4">
        <Errors error={query.error} />
        <Button onClick={() => query.refetch()}>Try again</Button>
        <Link className="ml-4 underline" to="/business/$businessId/invoices" params={{ businessId }}>
          Back to invoices
        </Link>
      </div>
    );
  if (
    invoiceId &&
    query.data &&
    (query.data.invoice.document_type === "quotation") !== (mode === "quotation")
  )
    return (
      <Navigate
        replace
        to={
          query.data.invoice.document_type === "quotation"
            ? "/business/$businessId/quotations/$invoiceId"
            : "/business/$businessId/invoices/$invoiceId"
        }
        params={{ businessId, invoiceId }}
      />
    );
  return (
    <InvoiceForm
      mode={mode}
      key={invoiceId ?? `new-${originalId ?? mode}`}
      invoice={invoiceId ? query.data?.invoice : undefined}
      original={originalId ? query.data?.invoice : linkedOriginal.data?.invoice}
    />
  );
}
const newLine = (): BusinessLine => ({
  description: "",
  kind: "service",
  sac: "",
  quantity: "1",
  unit_price: "",
  gst_rate: "18",
});
function localDate() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
}
function quotationNumber(numbering: BusinessBootstrap["quotation_numbering"]) {
  return numbering.next_quotation_number;
}
function nextQuotationNumbers(value: string, financialYear: number) {
  const serial = value.match(/^(\d+)\/(\d{4})-(\d{2})$/);
  if (serial && Number(serial[2]) === financialYear && Number(serial[3]) === (financialYear + 1) % 100) {
    const current = Number(serial[1]);
    if (current < 1 || current > 999_999) return null;
    return [1, 2].map((step) => `${current + step}/${serial[2]}-${serial[3]}`);
  }
  const parts = value.match(/^([A-Za-z0-9/._-]*?)(\d{1,8})$/);
  if (!parts || value.length > 60) return null;
  const current = Number(parts[2]);
  if (current < 1 || current > 999_997) return null;
  return [1, 2].map((step) => `${parts[1]}${String(current + step).padStart(parts[2].length, "0")}`);
}
function QuotationNumberPreview({ value, financialYear }: { value: string; financialYear: number }) {
  const next = nextQuotationNumbers(value, financialYear);
  if (!next) return <p className="text-sm text-muted-foreground">Enter a quotation number ending in digits, such as GR-50.</p>;
  return <div className="space-y-1 text-sm"><p>This quotation: <strong>{value}</strong></p><p className="text-muted-foreground">Next quotations: {next.join(", ")}, …</p></div>;
}
function invoiceNumber(numbering: BusinessBootstrap["invoice_numbering"]) {
  const year = numbering.financial_year;
  return numbering.style === "serial_fy"
    ? `${numbering.next_number}/${year}-${String(year + 1).slice(-2)}`
    : `INV/${String(year).slice(-2)}${String(year + 1).slice(-2)}/${String(numbering.next_number).padStart(4, "0")}`;
}

function invoiceFormValue(
  invoice: BusinessInvoice | undefined,
  original: BusinessInvoice | undefined,
  mode: "invoice" | "quotation",
): InvoiceInput {
  return {
    customer_id: invoice?.customer_id ?? original?.customer_id ?? "",
    billing_address_id: invoice?.billing_address_id ?? original?.billing_address_id ?? null,
    shipping_address_id: invoice?.shipping_address_id ?? original?.shipping_address_id ?? null,
    invoice_date: invoice?.invoice_date ?? localDate(),
    due_date: invoice?.due_date ?? "",
    valid_until: invoice?.valid_until ?? "",
    subject: invoice?.subject ?? "",
    place_of_supply: invoice?.place_of_supply ?? original?.place_of_supply ?? "",
    lines: (invoice?.lines ?? original?.lines)?.map((line) => ({
      description: line.description ?? "",
      kind: line.kind ?? "service",
      sac: line.sac ?? "",
      unit: line.unit ?? "",
      quantity: line.quantity,
      unit_price: line.unit_price,
      gst_rate: line.gst_rate,
    })) ?? [newLine()],
    notes: invoice?.notes ?? "",
    purchase_order_number:
      invoice?.purchase_order_number ?? original?.purchase_order_number ?? "",
    purchase_order_date: invoice?.purchase_order_date ?? original?.purchase_order_date ?? "",
    delivery_address: invoice?.delivery_address ?? original?.delivery_address ?? "",
    delivery_state_code:
      invoice?.delivery_state_code ?? original?.delivery_state_code ?? "",
    document_type: invoice?.document_type ?? (original ? "credit_note" : mode),
    original_invoice_id: invoice?.original_invoice_id ?? original?.id ?? null,
  };
}

function recoverNewDocument(key: string, initial: InvoiceInput) {
  try {
    const stored = window.localStorage.getItem(key);
    if (!stored) return null;
    const storedValue = JSON.parse(stored) as Record<string, unknown>;
    const wrapped = storedValue.form && typeof storedValue.form === "object";
    const recovered = (wrapped ? storedValue.form : storedValue) as Partial<InvoiceInput>;
    if (!recovered || !Array.isArray(recovered.lines)) return null;
    return {
      form: {
        ...initial,
        ...recovered,
        document_type: initial.document_type,
        original_invoice_id: initial.original_invoice_id,
        lines: recovered.lines,
      } as InvoiceInput,
      shippingTouched:
        wrapped && typeof storedValue.shippingTouched === "boolean"
          ? storedValue.shippingTouched
          : false,
    };
  } catch {
    try {
      window.localStorage.removeItem(key);
    } catch {
      // Recovery is best-effort when browser storage is unavailable.
    }
    return null;
  }
}

function InvoiceForm({
  invoice,
  original,
  mode,
}: {
  invoice?: BusinessInvoice;
  original?: BusinessInvoice;
  mode: "invoice" | "quotation";
}) {
  const businessId = useBusinessId();
  const queryKey = businessQueryKey(businessId);
  const data = useBusiness();
  const navigate = useNavigate();
  const cache = useQueryClient();
  const initialForm = invoiceFormValue(invoice, original, mode);
  const recoveryKey = `nila:business-document-draft:${businessId}:${
    original ? `credit-note-${original.id}` : mode
  }`;
  const recoveredOnLoad = useRef(false);
  const recoveredShippingTouched = useRef<boolean | null>(null);
  const [form, setForm] = useState<InvoiceInput>(() => {
    if (invoice) return initialForm;
    const recovered = recoverNewDocument(recoveryKey, initialForm);
    recoveredOnLoad.current = Boolean(recovered);
    recoveredShippingTouched.current = recovered?.shippingTouched ?? null;
    return recovered?.form ?? initialForm;
  });
  const cleanForm = useRef(JSON.stringify(initialForm));
  const allowNavigation = useRef(false);
  const initialShippingTouched = Boolean(invoice?.shipping_address_id || invoice?.delivery_address);
  const [shippingTouched, setShippingTouched] = useState(
    recoveredShippingTouched.current ?? initialShippingTouched,
  );
  const cleanShippingTouched = useRef(initialShippingTouched);
  const [saved, setSaved] = useState(invoice);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [message, setMessage] = useState(() =>
    recoveredOnLoad.current ? "Recovered your unsaved work." : "",
  );
  const [deleteOpen, setDeleteOpen] = useState(false);
  const deleteTrigger = useRef<HTMLButtonElement>(null);
  const cancelDelete = useRef<HTMLButtonElement>(null);
  const [cancelOpen, setCancelOpen] = useState(false);
  const [cancellationReason, setCancellationReason] = useState("");
  const cancelTrigger = useRef<HTMLButtonElement>(null);
  const keepInvoice = useRef<HTMLButtonElement>(null);
  const [sentOpen, setSentOpen] = useState(false);
  const [sentOn, setSentOn] = useState(localDate());
  const [acceptOpen, setAcceptOpen] = useState(false);
  const [purchaseOrderNumber, setPurchaseOrderNumber] = useState("");
  const [purchaseOrderDate, setPurchaseOrderDate] = useState("");
  const issued = Boolean(saved && saved.status !== "draft");
  const dirty =
    !issued &&
    (JSON.stringify(form) !== cleanForm.current || shippingTouched !== cleanShippingTouched.current);
  const transitionBusy = busy === "save" || busy === "issue" || busy === "delete";
  const credit = form.document_type === "credit_note";
  const quotation = form.document_type === "quotation";
  const documentPath = quotation ? "/business/$businessId/quotations" : "/business/$businessId/invoices";
  const [previewOpen, setPreviewOpen] = useState(false);
  const [numberingOpen, setNumberingOpen] = useState(false);
  const [numberingInput, setNumberingInput] = useState(data.quotation_numbering.next_quotation_number);
  const numberingMutation = useMutation({
    mutationFn: (next_quotation_number: string) => businessRequest("configureBusinessQuotationNumbering", { businessId, body: { numbering: { next_quotation_number } } }),
    retry: false,
    networkMode: "always",
    onSuccess: async (result) => {
      cache.setQueryData<BusinessBootstrap>(queryKey, (current) => current ? { ...current, quotation_numbering: result.quotation_numbering } : current);
      setNumberingInput(result.quotation_numbering.next_quotation_number);
      setNumberingOpen(false);
      await cache.invalidateQueries({ queryKey });
    },
  });
  const quoteYear = Number(form.invoice_date.slice(0, 4)) -
    (Number(form.invoice_date.slice(5, 7)) < 4 ? 1 : 0);
  const currentQuoteYear = quoteYear === data.quotation_numbering.financial_year;
  function openQuotationNumbering() {
    setNumberingInput(data.quotation_numbering.next_quotation_number);
    numberingMutation.reset();
    setNumberingOpen(true);
  }
  const calculation = useInvoiceCalculation(form, issued ? saved : undefined);
  const configured = Boolean(
    data.profile?.legal_name && data.profile?.address && data.profile?.state_code,
  );
  function clearRecovery() {
    if (invoice) return;
    try {
      window.localStorage.removeItem(recoveryKey);
    } catch {
      // Saving and navigation must still work when browser storage is unavailable.
    }
  }
  useEffect(() => {
    if (invoice || issued) return;
    try {
      if (dirty)
        window.localStorage.setItem(
          recoveryKey,
          JSON.stringify({ form, shippingTouched }),
        );
      else window.localStorage.removeItem(recoveryKey);
    } catch {
      // The navigation warning still protects the current tab.
    }
  }, [dirty, form, invoice, issued, recoveryKey, shippingTouched]);
  useBlocker({
    shouldBlockFn: () => {
      if (allowNavigation.current) {
        allowNavigation.current = false;
        return false;
      }
      if (transitionBusy) return true;
      if (!dirty) return false;
      const discard = window.confirm("Discard your unsaved changes?");
      if (discard) clearRecovery();
      return !discard;
    },
    enableBeforeUnload: dirty || transitionBusy,
  });
  function change(next: Partial<InvoiceInput>) {
    setForm({ ...form, ...next });
    setMessage("");
  }
  useEffect(() => {
    const customerId = Number(form.customer_id);
    if (!customerId) return;
    const customerAddresses = data.customer_addresses.filter(
      (address) => address.customer_id === customerId,
    );
    const billing = customerAddresses.find((address) => address.is_primary_billing);
    setForm((current) => ({
      ...current,
      ...(current.billing_address_id == null && billing
        ? { billing_address_id: billing.id }
        : {}),
      ...(() => {
        const shipping = customerAddresses.find((address) => address.is_primary_shipping);
        const billingId = current.billing_address_id ?? billing?.id ?? null;
        return current.shipping_address_id == null &&
          !current.delivery_address &&
          !shippingTouched &&
          shipping &&
          shipping.id !== billingId
          ? { shipping_address_id: shipping.id }
          : {};
      })(),
    }));
  }, [data.customer_addresses, form.customer_id, shippingTouched]);
  function lineChange(index: number, field: keyof BusinessLine, value: string) {
    change({
      lines: form.lines.map((line, i) => (i === index ? { ...line, [field]: value } : line)),
    });
  }
  async function save(event: FormEvent) {
    event.preventDefault();
    if (busy || issued) return;
    setBusy("save");
    setError(null);
    setMessage("");
    try {
      const result = await businessRequest(
        saved ? "updateBusinessInvoice" : "createBusinessInvoice",
        { businessId, id: saved?.id, body: { invoice: form } },
      );
      cache.setQueryData(["business-invoice", businessId, String(result.invoice.id)], result);
      cleanForm.current = JSON.stringify(form);
      cleanShippingTouched.current = shippingTouched;
      clearRecovery();
      setSaved(result.invoice);
      await cache.invalidateQueries({ queryKey });
      if (!saved) {
        allowNavigation.current = true;
        navigate({
          to: quotation ? "/business/$businessId/quotations/$invoiceId" : "/business/$businessId/invoices/$invoiceId",
          params: { businessId, invoiceId: String(result.invoice.id) },
          replace: true,
        });
      } else setMessage("Draft saved.");
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function issue() {
    if (busy || issued || !configured) return;
    if (
      form.delivery_address?.trim() &&
      !form.delivery_state_code &&
      !window.confirm("This ship-to site or address has no state. Finalize anyway?")
    ) {
      return;
    }
    if (quotation) {
      const formElement = document.getElementById("business-invoice-form") as HTMLFormElement | null;
      if (!formElement?.reportValidity()) return;
      setBusy("issue");
      setError(null);
      setMessage("");
      try {
        const result = await businessRequest("finalizeBusinessQuotation", { businessId,
          body: { invoice: form, ...(saved ? { id: saved.id } : {}) },
        });
        cache.setQueryData(["business-invoice", businessId, String(result.invoice.id)], result);
        cleanForm.current = JSON.stringify(form);
        cleanShippingTouched.current = shippingTouched;
        clearRecovery();
        setSaved(result.invoice);
        await cache.invalidateQueries({ queryKey });
        setMessage("Quotation ready to download.");
        if (!saved) {
          allowNavigation.current = true;
          navigate({
            to: "/business/$businessId/quotations/$invoiceId",
            params: { businessId, invoiceId: String(result.invoice.id) },
            replace: true,
          });
        }
      } catch (error) {
        setError(error as Error);
      } finally {
        setBusy(null);
      }
      return;
    }
    const formElement = document.getElementById("business-invoice-form") as HTMLFormElement | null;
    if (!formElement?.reportValidity()) return;
    setBusy("issue");
    setError(null);
    setMessage("");
    try {
      const result = await businessRequest("finalizeBusinessInvoice", { businessId,
        body: { invoice: form, ...(saved ? { id: saved.id } : {}) },
      });
      cache.setQueryData(["business-invoice", businessId, String(result.invoice.id)], result);
      cleanForm.current = JSON.stringify(form);
      cleanShippingTouched.current = shippingTouched;
      clearRecovery();
      setSaved(result.invoice);
      await cache.invalidateQueries({ queryKey });
      setMessage("Issued and shared with your CA.");
      if (!saved) {
        allowNavigation.current = true;
        navigate({
          to: "/business/$businessId/invoices/$invoiceId",
          params: { businessId, invoiceId: String(result.invoice.id) },
          replace: true,
        });
      }
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function download() {
    if (!saved || busy) return;
    setBusy("download");
    setError(null);
    try {
      await downloadInvoice(
        businessId,
        saved.id,
        quotation && saved.number
          ? `quotation-${saved.number.replaceAll("/", "-")}.pdf`
          : `invoice-${saved.id}.pdf`,
      );
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function deleteDraft() {
    if (!saved || issued || busy) return;
    setBusy("delete");
    setError(null);
    setMessage("");
    try {
      await businessRequest("deleteBusinessInvoice", { businessId, id: saved.id });
      clearRecovery();
      await cache.invalidateQueries({ queryKey });
      allowNavigation.current = true;
      navigate({ to: documentPath, params: { businessId }, replace: true });
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function copyDocument() {
    if (!saved || credit || busy || dirty) return;
    setBusy("copy");
    setError(null);
    setMessage("");
    try {
      const result = await businessRequest("copyBusinessInvoice", {
        businessId,
        id: saved.id,
      });
      cache.setQueryData(
        ["business-invoice", businessId, String(result.invoice.id)],
        result,
      );
      await cache.invalidateQueries({ queryKey });
      allowNavigation.current = true;
      navigate({
        to:
          result.invoice.document_type === "quotation"
            ? "/business/$businessId/quotations/$invoiceId"
            : "/business/$businessId/invoices/$invoiceId",
        params: { businessId, invoiceId: String(result.invoice.id) },
      });
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function cancelInvoice(event: FormEvent) {
    event.preventDefault();
    if (!saved || saved.status !== "issued" || quotation || credit || busy) return;
    const reason = cancellationReason.trim();
    if (!reason) return;
    setBusy("cancel");
    setError(null);
    setMessage("");
    try {
      const result = await businessRequest("cancelBusinessInvoice", {
        businessId,
        id: saved.id,
        body: { cancellation: { reason } },
      });
      cache.setQueryData(["business-invoice", businessId, String(saved.id)], result);
      setSaved(result.invoice);
      await cache.invalidateQueries({ queryKey });
      setCancellationReason("");
      setCancelOpen(false);
      setMessage("Invoice cancelled.");
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function quotationAction(
    action: "awaiting_po" | "accepted" | "declined" | "convert",
    details: {
      sent_on?: string;
      purchase_order_number?: string;
      purchase_order_date?: string;
    } = {},
  ) {
    if (!saved || busy || !quotation || !issued) return;
    setBusy(action);
    setError(null);
    setMessage("");
    try {
      if (action === "convert") {
        const result = await businessRequest("convertQuotation", { businessId, id: saved.id });
        cache.setQueryData(["business-invoice", businessId, String(result.quotation.id)], {
          invoice: result.quotation,
        });
        cache.setQueryData(["business-invoice", businessId, String(result.invoice.id)], {
          invoice: result.invoice,
        });
        await cache.invalidateQueries({ queryKey });
        navigate({
          to: "/business/$businessId/invoices/$invoiceId",
          params: { businessId, invoiceId: String(result.invoice.id) },
        });
      } else {
        const result = await businessRequest("setQuotationStatus", { businessId,
          id: saved.id,
          body: { status: action, ...details },
        });
        cache.setQueryData(["business-invoice", businessId, String(result.invoice.id)], result);
        setSaved(result.invoice);
        await cache.invalidateQueries({ queryKey });
        if (action === "awaiting_po") {
          setSentOpen(false);
          setMessage("Quotation marked sent and awaiting PO.");
        } else if (action === "accepted") {
          setAcceptOpen(false);
          setMessage("Quotation marked accepted.");
        } else {
          setMessage("Quotation marked declined.");
        }
      }
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function reviseQuotation() {
    if (!saved || busy || !quotation || !issued) return;
    setBusy("revise");
    setError(null);
    try {
      const result = await businessRequest("reviseBusinessQuotation", { businessId, id: saved.id });
      cache.setQueryData(["business-invoice", businessId, String(result.invoice.id)], result);
      await cache.invalidateQueries({ queryKey });
      navigate({
        to: "/business/$businessId/quotations/$invoiceId",
        params: { businessId, invoiceId: String(result.invoice.id) },
      });
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  return (
    <div className="mx-auto max-w-[1080px] space-y-5">
      <div className="sticky top-0 z-30 flex flex-wrap items-center justify-between gap-3 border-b bg-background/95 py-3 backdrop-blur supports-[backdrop-filter]:bg-background/85">
        <div className="flex items-center gap-3">
          <Button
            variant="ghost"
            size="sm"
            nativeButton={false}
            role="link"
            render={<Link to={documentPath} params={{ businessId }} />}
          >
            <ArrowLeft />
            {quotation ? "Quotations" : "Invoices"}
          </Button>
          <span className="text-sm text-muted-foreground">
            {saved?.number || (credit ? "New credit note" : "Draft")}
          </span>
          {dirty && <span className="text-sm text-muted-foreground">Unsaved changes</span>}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button type="button" variant="outline" onClick={() => setPreviewOpen(true)}>
            <FileText /> Preview PDF
          </Button>
          {saved && !credit && (
            <Button
              type="button"
              variant="outline"
              disabled={Boolean(busy) || dirty}
              title={dirty ? "Save your changes before copying this document." : undefined}
              onClick={copyDocument}
            >
              {busy === "copy" ? "Copying…" : "Copy to new draft"}
            </Button>
          )}
          {issued ? (
            <>
              {!credit && !quotation && saved?.status === "issued" && (
                <Button
                  variant="outline"
                  nativeButton={false}
                  role="link"
                  render={
                    <Link to="/business/$businessId/invoices/new" params={{ businessId }} search={{ credit_for: String(saved!.id) }} />
                  }
                >
                  Create credit note
                </Button>
              )}
              {!credit && !quotation && saved?.status === "issued" && (
                <Button
                  ref={cancelTrigger}
                  type="button"
                  variant="outline"
                  disabled={Boolean(busy)}
                  onClick={() => {
                    setError(null);
                    setCancellationReason("");
                    setCancelOpen(true);
                  }}
                >
                  Cancel invoice
                </Button>
              )}
              <Button onClick={download} disabled={Boolean(busy)}>
                <Download />
                {busy === "download" ? "Downloading…" : "Download PDF"}
              </Button>
            </>
          ) : (
            <>
              {saved && (
                <Button
                  ref={deleteTrigger}
                  type="button"
                  variant="outline"
                  disabled={Boolean(busy)}
                  onClick={() => {
                    setError(null);
                    setDeleteOpen(true);
                  }}
                >
                  <Trash2 /> Delete draft
                </Button>
              )}
              <Button
                form="business-invoice-form"
                type="submit"
                variant="outline"
                disabled={Boolean(busy)}
              >
                {busy === "save" ? "Saving…" : "Save draft"}
              </Button>
              <Button
                type="button"
                onClick={issue}
                disabled={Boolean(busy) || !configured}
                aria-describedby="issue-help"
              >
                {busy === "issue"
                  ? quotation
                    ? "Finalizing…"
                    : "Issuing…"
                  : quotation
                    ? "Finalize quotation"
                    : credit
                      ? "Issue credit note"
                      : "Issue invoice"}
              </Button>
            </>
          )}
        </div>
      </div>
      {saved?.status === "cancelled" && (
        <section
          aria-label="Cancellation details"
          className="flex flex-wrap items-start justify-between gap-3 border-y py-3 text-sm"
        >
          <div className="space-y-1">
            <Badge variant="destructive">Cancelled</Badge>
            <p>{saved.cancellation_reason}</p>
          </div>
          {saved.cancelled_at && (
            <p className="text-muted-foreground">
              {new Intl.DateTimeFormat("en-IN", {
                dateStyle: "medium",
                timeStyle: "short",
                timeZone: "Asia/Kolkata",
              }).format(new Date(saved.cancelled_at))}
              <span> IST</span>
            </p>
          )}
        </section>
      )}
      {quotation && issued && saved && (
        <div className="flex flex-wrap items-center justify-between gap-3 border-y py-3">
          <p className="text-sm">
            {quotationLabel(saved!)}
            {saved.sent_on && (
              <span className="ml-3 text-muted-foreground">
                Sent {businessDocumentDate(saved.sent_on)}
              </span>
            )}
            {saved.purchase_order_number && saved.status === "accepted" && (
              <span className="ml-3 text-muted-foreground">
                PO {saved.purchase_order_number}
                {saved.purchase_order_date
                  ? ` · ${businessDocumentDate(saved.purchase_order_date)}`
                  : ""}
              </span>
            )}
            <span className="ml-3 text-muted-foreground">
              Quotations are not included in sales or GST workings.
            </span>
          </p>
          <div className="flex flex-wrap gap-2">
            <Button variant="outline" disabled={Boolean(busy)} onClick={reviseQuotation}>
              {busy === "revise" ? "Creating…" : "Revise quotation"}
            </Button>
            {saved.converted_invoice_id ? (
              <Button
                nativeButton={false}
                role="link"
                render={
                  <Link
                    to="/business/$businessId/invoices/$invoiceId"
                    params={{ businessId, invoiceId: String(saved.converted_invoice_id) }}
                  />
                }
              >
                Open invoice
              </Button>
            ) : (
              <>
                {saved.status !== "accepted" && saved.status !== "awaiting_po" && (
                  <Button
                    variant="outline"
                    disabled={Boolean(busy)}
                    onClick={() => {
                      setError(null);
                      setSentOn(saved.sent_on || localDate());
                      setSentOpen(true);
                    }}
                  >
                    Mark sent
                  </Button>
                )}
                {saved.status === "awaiting_po" && (
                  <Button
                    variant="outline"
                    disabled={Boolean(busy)}
                    onClick={() => {
                      setError(null);
                      setPurchaseOrderNumber(saved.purchase_order_number || "");
                      setPurchaseOrderDate(saved.purchase_order_date || "");
                      setAcceptOpen(true);
                    }}
                  >
                    Mark accepted
                  </Button>
                )}
                {saved.status !== "declined" && (
                  <Button
                    variant="outline"
                    disabled={Boolean(busy)}
                    onClick={() => quotationAction("declined")}
                  >
                    {busy === "declined" ? "Saving…" : "Mark declined"}
                  </Button>
                )}
                {saved.status === "accepted" && (
                  <Button disabled={Boolean(busy)} onClick={() => quotationAction("convert")}>
                    {busy === "convert" ? "Converting…" : "Convert to invoice"}
                  </Button>
                )}
              </>
            )}
          </div>
        </div>
      )}
      <Errors error={error} />
      {message && (
        <p role="status" className="text-sm">
          {message}
        </p>
      )}
      {!configured && !issued && (
        <p className="text-sm text-muted-foreground">
          Complete your{" "}
          <Link to="/business/$businessId/settings/$section" params={{ businessId, section: "business" }} className="underline underline-offset-4">
            business details
          </Link>{" "}
          {quotation
            ? "before finalizing. You can still save a draft."
            : "before issuing. You can still save a draft."}
        </p>
      )}
      {original && (
        <p className="text-sm text-muted-foreground">
          Credit against {original.number}. Keep only the services and amounts being credited.
        </p>
      )}
      <form id="business-invoice-form" onSubmit={save}>
        <InvoiceDocument
          value={form}
          saved={saved}
          original={original}
          business={data}
          calculation={calculation.value}
          calculating={calculation.pending}
          onChange={change}
          onShippingInteraction={setShippingTouched}
          nextQuotationNumber={
            quotation && !issued && currentQuoteYear
              ? quotationNumber(data.quotation_numbering)
              : undefined
          }
          onChangeQuotationNumbering={
            quotation && !issued && currentQuoteYear && data.quotation_numbering.editable
              ? openQuotationNumbering
              : undefined
          }
          disabled={issued || Boolean(busy)}
        />
      </form>
      {calculation.error && (
        <p role="alert" className="mx-auto max-w-[920px] text-sm text-destructive">
          {calculation.error}
        </p>
      )}
      <p
        id="issue-help"
        className={
          quotation && !issued ? "sr-only" : "mx-auto max-w-[920px] text-sm text-muted-foreground"
        }
      >
        {quotation
          ? issued
            ? "The finalized quotation is locked. Record the customer’s response before converting it to an invoice."
            : "Finalizing locks this quotation and creates its PDF."
          : issued
            ? saved?.status === "cancelled"
              ? "This invoice is cancelled and remains locked. Its original PDF is still available."
              : "Issued documents are locked. Use a credit note to reduce or reverse an invoice."
            : "Issuing saves the current invoice, assigns a number, locks it, and shares it with your CA."}
      </p>
      <AlertDialog
        open={cancelOpen}
        onOpenChange={(open) => {
          if (!open && busy !== "cancel") setCancelOpen(false);
        }}
      >
        <AlertDialogContent initialFocus={keepInvoice} finalFocus={cancelTrigger}>
          <form className="contents" onSubmit={cancelInvoice}>
            <AlertDialogHeader>
              <AlertDialogTitle>Cancel invoice?</AlertDialogTitle>
              <AlertDialogDescription>
                The invoice number and original PDF will be kept. The cancellation will be
                included in your GST records.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <Field label="Reason for cancellation" id="invoice-cancellation-reason">
              <Textarea
                id="invoice-cancellation-reason"
                value={cancellationReason}
                required
                maxLength={500}
                disabled={busy === "cancel"}
                onChange={(event) => {
                  setCancellationReason(event.target.value);
                  setError(null);
                }}
              />
              <p className="text-xs text-muted-foreground">
                {cancellationReason.length}/500 characters
              </p>
            </Field>
            <Errors error={error} />
            <AlertDialogFooter>
              <AlertDialogCancel ref={keepInvoice} disabled={busy === "cancel"}>
                Keep invoice
              </AlertDialogCancel>
              <AlertDialogAction
                type="submit"
                variant="destructive"
                disabled={busy === "cancel" || !cancellationReason.trim()}
              >
                {busy === "cancel" ? "Cancelling…" : "Cancel invoice"}
              </AlertDialogAction>
            </AlertDialogFooter>
          </form>
        </AlertDialogContent>
      </AlertDialog>
      <Dialog open={sentOpen} onOpenChange={(open) => busy !== "awaiting_po" && setSentOpen(open)}>
        <DialogContent className="sm:max-w-md">
          <DialogTitle>Mark quotation sent</DialogTitle>
          <DialogDescription>
            This moves the quotation to Awaiting PO.
          </DialogDescription>
          <form
            className="space-y-5"
            onSubmit={(event) => {
              event.preventDefault();
              if (sentOn) quotationAction("awaiting_po", { sent_on: sentOn });
            }}
          >
            <Field label="Sent date" id="quotation-sent-on">
              <Input
                id="quotation-sent-on"
                type="date"
                required
                value={sentOn}
                disabled={busy === "awaiting_po"}
                onChange={(event) => setSentOn(event.target.value)}
              />
            </Field>
            <Errors error={error} />
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" disabled={busy === "awaiting_po"} onClick={() => setSentOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={busy === "awaiting_po" || !sentOn}>
                {busy === "awaiting_po" ? "Saving…" : "Mark sent"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
      <Dialog open={acceptOpen} onOpenChange={(open) => busy !== "accepted" && setAcceptOpen(open)}>
        <DialogContent className="sm:max-w-md">
          <DialogTitle>Mark quotation accepted</DialogTitle>
          <DialogDescription>
            Add the customer’s PO details if you have them. Both fields are optional.
          </DialogDescription>
          <form
            className="space-y-5"
            onSubmit={(event) => {
              event.preventDefault();
              quotationAction("accepted", {
                purchase_order_number: purchaseOrderNumber.trim(),
                purchase_order_date: purchaseOrderDate,
              });
            }}
          >
            <Field label="PO number (optional)" id="quotation-po-number">
              <Input
                id="quotation-po-number"
                maxLength={100}
                value={purchaseOrderNumber}
                disabled={busy === "accepted"}
                onChange={(event) => setPurchaseOrderNumber(event.target.value)}
              />
            </Field>
            <Field label="PO date (optional)" id="quotation-po-date">
              <Input
                id="quotation-po-date"
                type="date"
                value={purchaseOrderDate}
                disabled={busy === "accepted"}
                onChange={(event) => setPurchaseOrderDate(event.target.value)}
              />
            </Field>
            <Errors error={error} />
            <div className="flex justify-end gap-2">
              <Button type="button" variant="outline" disabled={busy === "accepted"} onClick={() => setAcceptOpen(false)}>
                Cancel
              </Button>
              <Button type="submit" disabled={busy === "accepted"}>
                {busy === "accepted" ? "Saving…" : "Mark accepted"}
              </Button>
            </div>
          </form>
        </DialogContent>
      </Dialog>
      <AlertDialog
        open={deleteOpen}
        onOpenChange={(open) => {
          if (!open && busy !== "delete") setDeleteOpen(false);
        }}
      >
        <AlertDialogContent initialFocus={cancelDelete} finalFocus={deleteTrigger}>
          <AlertDialogHeader>
            <AlertDialogTitle>
              Delete draft {quotation ? "quotation" : credit ? "credit note" : "invoice"}?
            </AlertDialogTitle>
            <AlertDialogDescription>
              This permanently deletes this draft. It cannot be undone.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <Errors error={error} />
          <AlertDialogFooter>
            <AlertDialogCancel ref={cancelDelete} disabled={busy === "delete"}>
              Cancel
            </AlertDialogCancel>
            <AlertDialogAction
              variant="destructive"
              disabled={busy === "delete"}
              onClick={deleteDraft}
            >
              {busy === "delete" ? "Deleting…" : "Delete draft"}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
      <Dialog open={numberingOpen} onOpenChange={setNumberingOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogTitle>Set quotation numbering</DialogTitle>
          <DialogDescription>This sets the number for this quotation and how future quotations continue.</DialogDescription>
          <form className="space-y-5" onSubmit={(event) => { event.preventDefault(); if (!numberingMutation.isPending && nextQuotationNumbers(numberingInput, data.quotation_numbering.financial_year)) numberingMutation.mutate(numberingInput); }}>
            <Field label="Quotation number" id="quotation-number-input">
              <Input id="quotation-number-input" value={numberingInput} maxLength={60} onChange={(event) => { numberingMutation.reset(); setNumberingInput(event.target.value); }} autoFocus />
            </Field>
            <QuotationNumberPreview value={numberingInput} financialYear={data.quotation_numbering.financial_year} />
            <Errors error={numberingMutation.error} />
            <div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={() => setNumberingOpen(false)}>Cancel</Button><Button type="submit" disabled={numberingMutation.isPending || !nextQuotationNumbers(numberingInput, data.quotation_numbering.financial_year)}>{numberingMutation.isPending ? "Saving…" : "Save"}</Button></div>
          </form>
        </DialogContent>
      </Dialog>
      <Dialog open={previewOpen} onOpenChange={setPreviewOpen}>
        <DialogContent className="max-h-[95vh] overflow-hidden p-0 sm:max-w-[960px]">
          <div className="border-b px-5 py-4">
            <DialogTitle>PDF preview</DialogTitle>
            <DialogDescription className="mt-1">
              {quotation
                ? issued
                  ? "The saved finalized quotation."
                  : "Draft quotation. No quotation number is assigned until you finalize it."
                : issued
                  ? "The saved original issued to your customer."
                  : "Draft preview. No invoice number is assigned until you issue it."}
            </DialogDescription>
          </div>
          {previewOpen && (
            <InvoicePreview invoice={form} issuedId={issued ? saved!.id : undefined} />
          )}
        </DialogContent>
      </Dialog>
    </div>
  );
}

function useInvoiceCalculation(invoice: InvoiceInput, issued?: BusinessInvoice) {
  const businessId = useBusinessId();
  const key = JSON.stringify({ businessId, lines: invoice.lines, place_of_supply: invoice.place_of_supply });
  const token = useMemo(() => Symbol(key), [key]);
  const [result, setResult] = useState<{
    token: symbol;
    value?: InvoiceCalculation;
    error?: string;
  } | null>(null);
  const ready = Boolean(
    invoice.place_of_supply &&
      invoice.lines.length &&
      invoice.lines.every(
        (line) => Number(line.quantity) > 0 && Number(line.unit_price) > 0 && line.gst_rate,
      ),
  );
  useEffect(() => {
    if (issued || !ready) return;
    const controller = new AbortController();
    const timer = setTimeout(async () => {
      try {
        const value = await businessRequest("calculateBusinessInvoice", { businessId,
          body: { invoice: { lines: invoice.lines, place_of_supply: invoice.place_of_supply } },
          signal: controller.signal,
        });
        if (!controller.signal.aborted) setResult({ token, value });
      } catch (error) {
        if (!controller.signal.aborted)
          setResult({
            token,
            error:
              error instanceof BusinessApiError && error.status === 422
                ? undefined
                : "Totals could not be calculated. Check your connection and edit a line to retry.",
          });
      }
    }, 200);
    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [businessId, token, ready, issued]);
  if (issued)
    return {
      value: {
        totals: issued.totals!,
        total_in_words: issued.snapshot.total_in_words ?? "",
        lines: issued.snapshot.lines ?? [],
      },
      pending: false,
    };
  const current = result?.token === token ? result : null;
  return { value: current?.value ?? null, pending: ready && !current, error: current?.error };
}

function InvoicePreview({ invoice, issuedId }: { invoice: InvoiceInput; issuedId?: number }) {
  const businessId = useBusinessId();
  const quotation = invoice.document_type === "quotation";
  const data = useBusiness();
  const [attempt, setAttempt] = useState(0);
  const [result, setResult] = useState<{ token: symbol; url?: string; error?: Error } | null>(null);
  const complete = Boolean(
    invoice.customer_id &&
      invoice.place_of_supply &&
      invoice.invoice_date &&
      invoice.lines.length &&
      invoice.lines.every(
        (line) =>
          line.description.trim() &&
          (line.kind === "goods"
            ? /^(?!99)[0-9]{6}([0-9]{2})?$/.test(line.sac) && Boolean(line.unit)
            : /^99[0-9]{4}$/.test(line.sac)) &&
          Number(line.quantity) > 0 &&
          Number(line.unit_price) > 0,
      ),
  );
  // Include party details so refreshing a customer or profile also refreshes the PDF.
  const requestKey = issuedId
    ? `issued:${businessId}:${issuedId}`
    : JSON.stringify({
        businessId,
        invoice,
        profile: data.profile,
        customer: data.customers.find((customer) => customer.id === Number(invoice.customer_id)),
        addresses: data.customer_addresses.filter(
          (address) =>
            address.customer_id === Number(invoice.customer_id) &&
            (address.id === Number(invoice.billing_address_id) ||
              address.id === Number(invoice.shipping_address_id)),
        ),
      });
  const requestToken = useMemo(() => Symbol(requestKey), [requestKey]);
  useEffect(() => {
    if (!issuedId && !complete) return;
    const controller = new AbortController();
    let objectUrl: string | undefined;
    const timer = setTimeout(
      async () => {
        try {
          const blob = await fetchInvoicePdf(businessId, issuedId ?? invoice, controller.signal);
          if (controller.signal.aborted) return;
          objectUrl = URL.createObjectURL(blob);
          setResult({ token: requestToken, url: objectUrl });
        } catch (error) {
          if (!controller.signal.aborted) setResult({ token: requestToken, error: error as Error });
        }
      },
      issuedId ? 0 : 500,
    );
    return () => {
      clearTimeout(timer);
      controller.abort();
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [businessId, requestToken, complete, issuedId, attempt]);
  const current = result?.token === requestToken ? result : null;
  const ready = issuedId || complete;
  return (
    <section aria-label="Invoice preview" className="min-w-0 overflow-hidden bg-muted/30">
      <div className="flex items-center justify-between gap-3 border-b bg-background px-4 py-3">
        <h2 className="text-sm font-medium">
          {issuedId ? (quotation ? "Quotation PDF" : "Issued PDF") : "PDF preview"}
        </h2>
        <span className="text-xs text-muted-foreground">
          {issuedId ? "Saved original" : quotation ? "Draft quotation" : "Draft · not issued"}
        </span>
      </div>
      <div className="h-[min(75vh,850px)] min-h-[360px]">
        {!ready ? (
          <div className="flex h-full flex-col items-center justify-center gap-3 px-8 text-center">
            <FileText className="size-8 text-muted-foreground" />
            <p className="text-sm font-medium">
              {quotation ? "Your quotation will appear here" : "Your invoice will appear here"}
            </p>
            <p className="max-w-xs text-sm text-muted-foreground">
              Choose a customer and place of supply, then add an item, HSN/SAC and rate.
            </p>
          </div>
        ) : current?.error ? (
          <div className="flex h-full flex-col items-center justify-center gap-4 p-6">
            <Errors error={current.error} />
            <Button
              variant="outline"
              onClick={() => {
                setResult(null);
                setAttempt((value) => value + 1);
              }}
            >
              Retry preview
            </Button>
          </div>
        ) : current?.url ? (
          <Suspense
            fallback={
              <p role="status" className="p-6 text-sm text-muted-foreground">
                Opening PDF…
              </p>
            }
          >
            <SourcePdf url={current.url} pages={[]} />
          </Suspense>
        ) : (
          <div
            role="status"
            className="flex h-full items-center justify-center gap-2 text-sm text-muted-foreground"
          >
            <Spinner aria-hidden="true" />
            {issuedId ? "Opening issued PDF…" : "Updating preview…"}
          </div>
        )}
      </div>
    </section>
  );
}
