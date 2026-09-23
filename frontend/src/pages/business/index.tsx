import { InvoiceDocument, type InvoiceCalculation } from "@/components/business/invoice-document";
import { RecordTableLink, RecordTableRow } from "@/components/record-table-row";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogTitle } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { NativeSelect } from "@/components/ui/native-select";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  BusinessApiError,
  businessRequest,
  downloadInvoice,
  fetchInvoicePdf,
  type BusinessBootstrap,
  type BusinessCustomer,
  type BusinessInvoice,
  type BusinessLine,
  type InvoiceInput,
} from "@/lib/business-api";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Link,
  Navigate,
  Outlet,
  useLocation,
  useNavigate,
  useParams,
  useSearch,
} from "@tanstack/react-router";
import { ArrowLeft, Download, FileText, Loader2, Plus } from "lucide-react";
import {
  createContext,
  lazy,
  Suspense,
  useContext,
  useEffect,
  useMemo,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import { ServicesPage } from "./services";

const SourcePdf = lazy(() => import("@/components/source-pdf"));
const Workspace = createContext<BusinessBootstrap | null>(null);
const queryKey = ["business"];
const retry = (count: number, error: Error) =>
  !(error instanceof BusinessApiError && error.status < 500) && count < 1;
const money = (paise: number) =>
  new Intl.NumberFormat("en-IN", { style: "currency", currency: "INR" }).format(paise / 100);
function useBusiness() {
  const value = useContext(Workspace);
  if (!value) throw new Error("Business workspace missing");
  return value;
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
  required = true,
}: {
  id: string;
  value: string;
  onChange: (value: string) => void;
  required?: boolean;
}) {
  const data = useBusiness();
  return (
    <NativeSelect
      id={id}
      value={value}
      onChange={(e) => onChange(e.target.value)}
      required={required}
    >
      <option value="">Choose state</option>
      {data.states.map((state) => (
        <option key={state.code} value={state.code}>
          {state.name}
        </option>
      ))}
    </NativeSelect>
  );
}
export function BusinessLayout() {
  const location = useLocation();
  const editingInvoice = /\/business\/(?:invoices|quotations)\/.+/.test(location.pathname);
  const query = useQuery({
    queryKey,
    queryFn: ({ signal }) => businessRequest("getBusiness", { signal }),
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
            <Link to="/business/invoices" className="font-semibold">
              Nila{" "}
              <span className="ml-3 font-normal text-muted-foreground">
                {query.data.business.name}
              </span>
            </Link>
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
                ["/business/invoices", "Invoices"],
                ["/business/quotations", "Quotations"],
                ["/business/customers", "Customers"],
                ["/business/services", "Services"],
                ["/business/settings", "Business details"],
              ] as const
            ).map(([path, title]) => (
              <Link
                key={path}
                to={path}
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
          <Outlet />
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
  if (invoice.status === "accepted") return "Accepted";
  if (invoice.status === "declined") return "Declined";
  return "Ready";
}
export function BusinessInvoices({ mode = "invoice" }: { mode?: "invoice" | "quotation" }) {
  const data = useBusiness();
  const quotation = mode === "quotation";
  const documents = data.invoices.filter(
    (invoice) => (invoice.document_type === "quotation") === quotation,
  );
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
          render={<Link to={quotation ? "/business/quotations/new" : "/business/invoices/new"} />}
        >
          <Plus />
          {quotation ? "New quotation" : "New invoice"}
        </Button>
      </div>
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
            {documents.map((invoice) => (
              <RecordTableRow key={invoice.id}>
                <TableCell>
                  <RecordTableLink
                    className="font-medium underline-offset-4 hover:underline"
                    to={
                      quotation
                        ? "/business/quotations/$invoiceId"
                        : "/business/invoices/$invoiceId"
                    }
                    params={{ invoiceId: String(invoice.id) }}
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
                <TableCell>{invoice.invoice_date}</TableCell>
                {quotation && <TableCell>{invoice.valid_until || "—"}</TableCell>}
                <TableCell>
                  <Badge variant={invoice.status !== "draft" ? "secondary" : "outline"}>
                    {quotation
                      ? quotationLabel(invoice)
                      : invoice.status === "issued"
                        ? "Issued"
                        : "Draft"}
                  </Badge>
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
          </TableBody>
        </Table>
      </div>
    </div>
  );
}

export function BusinessCustomers() {
  const data = useBusiness();
  const cache = useQueryClient();
  const empty = { name: "", gstin: "", address: "", state_code: "" };
  const [editing, setEditing] = useState<number | null>(null);
  const [form, setForm] = useState(empty);
  const [show, setShow] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await businessRequest(editing ? "updateBusinessCustomer" : "createBusinessCustomer", {
        id: editing ?? undefined,
        body: { customer: form },
      });
      await cache.invalidateQueries({ queryKey });
      setShow(false);
      setForm(empty);
      setEditing(null);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }
  function edit(customer: BusinessCustomer) {
    setEditing(customer.id);
    setForm({
      name: customer.name,
      gstin: customer.gstin ?? "",
      address: customer.address,
      state_code: customer.state_code,
    });
    setError(null);
    setShow(true);
  }
  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold">Customers</h1>
        <Button
          onClick={() => {
            setEditing(null);
            setForm(empty);
            setError(null);
            setShow(true);
          }}
        >
          <Plus /> Add customer
        </Button>
      </div>
      {show && (
        <form
          id="business-customer-form"
          onSubmit={submit}
          className="max-w-xl space-y-5 rounded-lg border p-5"
        >
          <h2 className="text-lg font-medium">{editing ? "Edit customer" : "Add customer"}</h2>
          <Errors error={error} />
          <fieldset disabled={busy} className="space-y-4">
            <Field label="Customer name" id="customer-name">
              <Input
                id="customer-name"
                required
                value={form.name}
                onChange={(e) => setForm({ ...form, name: e.target.value })}
              />
            </Field>
            <Field label="GSTIN (optional)" id="customer-gstin">
              <Input
                id="customer-gstin"
                value={form.gstin}
                maxLength={15}
                onChange={(e) => setForm({ ...form, gstin: e.target.value.toUpperCase() })}
              />
            </Field>
            <Field label="Billing address" id="customer-address">
              <Input
                id="customer-address"
                required
                value={form.address ?? ""}
                onChange={(e) => setForm({ ...form, address: e.target.value })}
              />
            </Field>
            <Field label="State" id="customer-state">
              <StateSelect
                id="customer-state"
                value={form.state_code ?? ""}
                onChange={(value) => setForm({ ...form, state_code: value })}
              />
            </Field>
            <div className="flex gap-3">
              <Button type="submit">{busy ? "Saving…" : "Save customer"}</Button>
              <Button type="button" variant="outline" onClick={() => setShow(false)}>
                Cancel
              </Button>
            </div>
          </fieldset>
        </form>
      )}
      <div className="overflow-hidden rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Customer</TableHead>
              <TableHead>GSTIN</TableHead>
              <TableHead>
                <span className="sr-only">Actions</span>
              </TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {data.customers.map((customer) => (
              <TableRow key={customer.id}>
                <TableCell className="font-medium">{customer.name}</TableCell>
                <TableCell>{customer.gstin || "Unregistered"}</TableCell>
                <TableCell className="text-right">
                  <Button variant="ghost" onClick={() => edit(customer)}>
                    Edit<span className="sr-only"> {customer.name}</span>
                  </Button>
                </TableCell>
              </TableRow>
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

export function BusinessServices() {
  const data = useBusiness();
  return <ServicesPage services={data.services ?? []} />;
}

export function BusinessSettings() {
  const data = useBusiness();
  const cache = useQueryClient();
  const [form, setForm] = useState<
    import("@/lib/generated/workspace").components["schemas"]["BusinessProfileInput"]
  >(() => ({
    legal_name: data.profile?.legal_name ?? data.business.name,
    address: data.profile?.address ?? "",
    state_code: data.profile?.state_code ?? data.business.gstin?.slice(0, 2) ?? "",
    e_invoice_not_applicable: data.profile?.e_invoice_not_applicable ?? false,
    domestic_services_only: data.profile?.domestic_services_only ?? false,
  }));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const [saved, setSaved] = useState(false);
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    setSaved(false);
    try {
      await businessRequest("updateBusinessProfile", { body: { profile: form } });
      await cache.invalidateQueries({ queryKey });
      setSaved(true);
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(false);
    }
  }
  return (
    <form onSubmit={submit} className="max-w-xl space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Business details</h1>
        <p className="mt-2 text-sm text-muted-foreground">These details appear on your invoices.</p>
      </div>
      <Errors error={error} />
      {saved && (
        <p role="status" className="text-sm">
          Business details saved.
        </p>
      )}
      <fieldset disabled={busy} className="space-y-5">
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
          <p className="text-sm text-muted-foreground">
            Ask your CA to correct your GSTIN if needed.
          </p>
        </Field>
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
        <Field label="Services covered" id="business-domestic">
          <NativeSelect
            id="business-domestic"
            value={form.domestic_services_only ? "yes" : "no"}
            onChange={(e) => {
              setSaved(false);
              setForm({ ...form, domestic_services_only: e.target.value === "yes" });
            }}
          >
            <option value="no">Not confirmed</option>
            <option value="yes">I will use Nila only for domestic services</option>
          </NativeSelect>
        </Field>
        <Field label="E-invoicing applicability" id="business-einvoice">
          <NativeSelect
            id="business-einvoice"
            value={form.e_invoice_not_applicable ? "yes" : "no"}
            onChange={(e) => {
              setSaved(false);
              setForm({ ...form, e_invoice_not_applicable: e.target.value === "yes" });
            }}
          >
            <option value="no">Not confirmed with my CA</option>
            <option value="yes">My CA confirmed e-invoicing does not apply</option>
          </NativeSelect>
          <p className="text-sm text-muted-foreground">
            Confirm this with your CA before issuing invoices. Nila does not generate an IRN.
          </p>
        </Field>
        <Button type="submit">{busy ? "Saving…" : "Save business details"}</Button>
      </fieldset>
    </form>
  );
}

export function BusinessInvoiceEditor({ mode = "invoice" }: { mode?: "invoice" | "quotation" }) {
  const { invoiceId } = useParams({ strict: false });
  const params = useSearch({ strict: false });
  const originalId = mode === "invoice" ? params.credit_for : null;
  const query = useQuery({
    queryKey: ["business-invoice", invoiceId ?? originalId],
    queryFn: ({ signal }) =>
      businessRequest("getBusinessInvoice", { id: invoiceId ?? originalId!, signal }),
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
    queryKey: ["business-original-invoice", linkedOriginalId],
    queryFn: ({ signal }) =>
      businessRequest("getBusinessInvoice", { id: linkedOriginalId!, signal }),
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
        <Link className="ml-4 underline" to="/business/invoices">
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
            ? "/business/quotations/$invoiceId"
            : "/business/invoices/$invoiceId"
        }
        params={{ invoiceId }}
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
  sac: "",
  quantity: "1",
  unit_price: "",
  gst_rate: "18",
});
function localDate() {
  const now = new Date();
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")}`;
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
  const data = useBusiness();
  const navigate = useNavigate();
  const cache = useQueryClient();
  const [form, setForm] = useState<InvoiceInput>(() => ({
    customer_id: invoice?.customer_id ?? original?.customer_id ?? "",
    invoice_date: invoice?.invoice_date ?? localDate(),
    due_date: invoice?.due_date ?? "",
    valid_until: invoice?.valid_until ?? "",
    place_of_supply: invoice?.place_of_supply ?? original?.place_of_supply ?? "",
    lines: (invoice?.lines ?? original?.lines)?.map((line) => ({
      description: line.description ?? "",
      sac: line.sac ?? "",
      unit: line.unit ?? "",
      quantity: line.quantity,
      unit_price: line.unit_price,
      gst_rate: line.gst_rate,
    })) ?? [newLine()],
    notes: invoice?.notes ?? "",
    purchase_order_number: invoice?.purchase_order_number ?? original?.purchase_order_number ?? "",
    purchase_order_date: invoice?.purchase_order_date ?? original?.purchase_order_date ?? "",
    delivery_address: invoice?.delivery_address ?? original?.delivery_address ?? "",
    document_type: invoice?.document_type ?? (original ? "credit_note" : mode),
    original_invoice_id: invoice?.original_invoice_id ?? original?.id ?? null,
  }));
  const [saved, setSaved] = useState(invoice);
  const [dirty, setDirty] = useState(!invoice);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [message, setMessage] = useState("");
  const issued = Boolean(saved && saved.status !== "draft");
  const credit = form.document_type === "credit_note";
  const quotation = form.document_type === "quotation";
  const documentPath = quotation ? "/business/quotations" : "/business/invoices";
  const [previewOpen, setPreviewOpen] = useState(false);
  const calculation = useInvoiceCalculation(form, issued ? saved : undefined);
  const configured = Boolean(
    data.profile?.legal_name &&
      data.profile?.address &&
      data.profile?.state_code &&
      (quotation ||
        (data.profile?.e_invoice_not_applicable && data.profile?.domestic_services_only)),
  );
  function change(next: Partial<InvoiceInput>) {
    setForm({ ...form, ...next });
    setDirty(true);
    setMessage("");
  }
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
        { id: saved?.id, body: { invoice: form } },
      );
      cache.setQueryData(["business-invoice", String(result.invoice.id)], result);
      setSaved(result.invoice);
      setDirty(false);
      await cache.invalidateQueries({ queryKey });
      if (!saved)
        navigate({
          to: quotation ? "/business/quotations/$invoiceId" : "/business/invoices/$invoiceId",
          params: { invoiceId: String(result.invoice.id) },
          replace: true,
        });
      else setMessage("Draft saved.");
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function issue() {
    if (!saved || dirty || busy || issued) return;
    setBusy("issue");
    setError(null);
    setMessage("");
    try {
      const result = await businessRequest("issueBusinessInvoice", { id: saved.id });
      cache.setQueryData(["business-invoice", String(result.invoice.id)], result);
      setSaved(result.invoice);
      await cache.invalidateQueries({ queryKey });
      setMessage(quotation ? "Quotation ready to download." : "Issued and shared with your CA.");
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
        saved.id,
        quotation ? `quotation-${saved.id}.pdf` : `invoice-${saved.id}.pdf`,
      );
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  async function quotationAction(action: "accepted" | "declined" | "convert") {
    if (!saved || busy || !quotation || !issued) return;
    setBusy(action);
    setError(null);
    setMessage("");
    try {
      if (action === "convert") {
        const result = await businessRequest("convertQuotation", { id: saved.id });
        cache.setQueryData(["business-invoice", String(result.quotation.id)], {
          invoice: result.quotation,
        });
        cache.setQueryData(["business-invoice", String(result.invoice.id)], {
          invoice: result.invoice,
        });
        await cache.invalidateQueries({ queryKey });
        navigate({
          to: "/business/invoices/$invoiceId",
          params: { invoiceId: String(result.invoice.id) },
        });
      } else {
        const result = await businessRequest("setQuotationStatus", {
          id: saved.id,
          body: { status: action },
        });
        cache.setQueryData(["business-invoice", String(result.invoice.id)], result);
        setSaved(result.invoice);
        await cache.invalidateQueries({ queryKey });
        setMessage(
          action === "accepted" ? "Quotation marked accepted." : "Quotation marked declined.",
        );
      }
    } catch (error) {
      setError(error as Error);
    } finally {
      setBusy(null);
    }
  }
  return (
    <div className="mx-auto max-w-[1000px] space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <Button
            variant="ghost"
            size="sm"
            nativeButton={false}
            role="link"
            render={<Link to={documentPath} />}
          >
            <ArrowLeft />
            {quotation ? "Quotations" : "Invoices"}
          </Button>
          <span className="text-sm text-muted-foreground">
            {saved?.number || (credit ? "New credit note" : "Draft")}
          </span>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button type="button" variant="outline" onClick={() => setPreviewOpen(true)}>
            <FileText /> Preview PDF
          </Button>
          {issued ? (
            <>
              {!credit && !quotation && (
                <Button
                  variant="outline"
                  nativeButton={false}
                  role="link"
                  render={
                    <Link to="/business/invoices/new" search={{ credit_for: String(saved!.id) }} />
                  }
                >
                  Create credit note
                </Button>
              )}
              <Button onClick={download} disabled={Boolean(busy)}>
                <Download />
                {busy === "download" ? "Downloading…" : "Download PDF"}
              </Button>
            </>
          ) : (
            <>
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
                disabled={!saved || dirty || Boolean(busy) || !configured}
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
      {quotation && issued && saved && (
        <div className="flex flex-wrap items-center justify-between gap-3 border-y py-3">
          <p className="text-sm">
            {quotationLabel(saved!)}
            <span className="ml-3 text-muted-foreground">
              Quotations are not included in sales or GST workings.
            </span>
          </p>
          <div className="flex flex-wrap gap-2">
            {saved.converted_invoice_id ? (
              <Button
                nativeButton={false}
                role="link"
                render={
                  <Link
                    to="/business/invoices/$invoiceId"
                    params={{ invoiceId: String(saved.converted_invoice_id) }}
                  />
                }
              >
                Open invoice
              </Button>
            ) : (
              <>
                {saved.status !== "accepted" && (
                  <Button
                    variant="outline"
                    disabled={Boolean(busy)}
                    onClick={() => quotationAction("accepted")}
                  >
                    {busy === "accepted" ? "Saving…" : "Mark accepted"}
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
          <Link to="/business/settings" className="underline underline-offset-4">
            business details
          </Link>{" "}
          {quotation
            ? "before finalizing. You can still save a draft."
            : "and confirm the invoice scope with your CA before issuing. You can still save a draft."}
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
          disabled={issued || Boolean(busy)}
        />
      </form>
      {calculation.error && (
        <p role="alert" className="mx-auto max-w-[840px] text-sm text-destructive">
          {calculation.error}
        </p>
      )}
      <p id="issue-help" className="mx-auto max-w-[840px] text-sm text-muted-foreground">
        {quotation
          ? issued
            ? "The finalized quotation is locked. Record the customer’s response before converting it to an invoice."
            : "Save your draft before finalizing. Quotations are not sales invoices."
          : issued
            ? "Issued documents are locked. Use a credit note to reduce or reverse an invoice."
            : dirty || !saved
              ? "Save your draft before issuing. Only issued invoices are shared with your CA."
              : "Issuing assigns a number, locks the invoice, and shares it with your CA."}
      </p>
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
  const key = JSON.stringify({ lines: invoice.lines, place_of_supply: invoice.place_of_supply });
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
        const value = await businessRequest("calculateBusinessInvoice", {
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
  }, [token, ready, issued]);
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
          /^99[0-9]{4}$/.test(line.sac) &&
          Number(line.quantity) > 0 &&
          Number(line.unit_price) > 0,
      ),
  );
  // Include party details so refreshing a customer or profile also refreshes the PDF.
  const requestKey = issuedId
    ? `issued:${issuedId}`
    : JSON.stringify({
        invoice,
        profile: data.profile,
        customer: data.customers.find((customer) => customer.id === Number(invoice.customer_id)),
      });
  const requestToken = useMemo(() => Symbol(requestKey), [requestKey]);
  useEffect(() => {
    if (!issuedId && !complete) return;
    const controller = new AbortController();
    let objectUrl: string | undefined;
    const timer = setTimeout(
      async () => {
        try {
          const blob = await fetchInvoicePdf(issuedId ?? invoice, controller.signal);
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
  }, [requestToken, complete, issuedId, attempt]);
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
              Choose a customer and place of supply, then add a service, SAC and rate.
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
            <Loader2 className="size-4 animate-spin" />
            {issuedId ? "Opening issued PDF…" : "Updating preview…"}
          </div>
        )}
      </div>
    </section>
  );
}
