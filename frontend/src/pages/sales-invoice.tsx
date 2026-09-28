import type { components } from "@/lib/generated/workspace";
import { InvoiceRateDetails } from "@/components/invoice-rate-details";
import { Field, FieldLabel, FieldError } from "@/components/ui/field";
import { SalesRemovalActions } from "@/components/sales-removal-actions";
import { MoveSalesUpload } from "@/components/move-sales-upload";
import { InvoiceQueue } from "@/components/invoice-queue";
import type { PdfSession } from "@/components/source-pdf";
import { SourceSpreadsheet, type SpreadsheetPreferences } from "@/components/source-spreadsheet";
import { navigationShortcutBlocked, ShortcutHelpButton } from "@/components/keyboard-shortcuts";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Kbd } from "@/components/ui/kbd";
import { SelectField, SelectFieldOption } from "@/components/ui/select-field";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/components/ui/resizable";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { ToggleGroup, ToggleGroupItem } from "@/components/ui/toggle-group";
import { salesSearch } from "@/lib/route-search";
import { ApiError } from "@/lib/sales-api";
import {
  confirmSalesInvoiceIssue,
  fetchSalesInvoice,
  ReviewApiError,
  updateSalesInvoice,
  type ReviewChange,
  type ReviewValues,
  type SalesInvoiceReviewData,
} from "@/lib/sales-review-api";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useNavigate, useParams, useSearch } from "@tanstack/react-router";
import { ArrowLeft, ArrowRight, Check, ChevronDown, FileText, Pencil } from "lucide-react";
import { lazy, Suspense, useEffect, useRef, useState, type FormEvent } from "react";
import type { Layout } from "react-resizable-panels";

const SourcePdf = lazy(() => import("@/components/source-pdf"));
const filters = [
  { value: "needs_review", label: "Needs review" },
  { value: "ready", label: "Ready" },
  { value: "all", label: "All" },
] as const;
const fieldLabels: Record<string, string> = {
  invoice_number: "Invoice number",
  invoice_date: "Invoice date",
  buyer_name: "Customer",
  buyer_gstin: "Customer GSTIN",
  place_of_supply: "Place of supply",
  original_sale_category: "Original unregistered sale category",
  narration: "Narration",
  printed_total_taxable: "Printed taxable value",
  printed_total_tax: "Printed GST",
  printed_grand_total: "Printed invoice total",
  item_name: "Item name",
  description: "Description",
  hsn_sac: "HSN / SAC",
  quantity: "Quantity",
  uom: "Unit",
  printed_unit_price: "Printed unit price",
  printed_line_amount: "Printed line amount",
  printed_line_total: "Printed line total",
  printed_taxable_value: "Printed taxable value",
  line_amount_tax_inclusion: "Tax included in line amount",
  taxable_value: "Taxable value",
  cgst_rate: "CGST rate (%)",
  cgst_amount: "CGST amount",
  sgst_rate: "SGST rate (%)",
  sgst_amount: "SGST amount",
  igst_rate: "IGST rate (%)",
  igst_amount: "IGST amount",
};
const decimalFields = new Set([
  "quantity",
  "printed_unit_price",
  "printed_line_amount",
  "printed_line_total",
  "printed_taxable_value",
  "taxable_value",
  "cgst_rate",
  "cgst_amount",
  "sgst_rate",
  "sgst_amount",
  "igst_rate",
  "igst_amount",
  "printed_total_taxable",
  "printed_total_tax",
  "printed_grand_total",
]);

export default function SalesInvoiceReview() {
  const {
    clientId = "",
    period = "",
    invoiceId = "",
  } = useParams({ from: "/gst/$clientId/$period/sales/invoices/$invoiceId" });
  const params = useSearch({ from: "/gst/$clientId/$period/sales/invoices/$invoiceId" });
  const layout = useRef<Layout>({ source: 45, details: 55 });
  const spreadsheetLayout = useRef<Layout>({ source: 62, details: 38 });
  const spreadsheetPreferences = useRef<SpreadsheetPreferences>({ allColumns: false });
  const pdfZoom = useRef(1);
  const pdfSession = useRef<PdfSession | null>(null);
  useEffect(
    () => () => {
      pdfSession.current?.destroy();
      pdfSession.current = null;
    },
    [],
  );
  const key = ["sales-review", clientId, period, invoiceId];
  const query = useQuery({
    queryKey: key,
    queryFn: ({ signal }) => fetchSalesInvoice(clientId, period, invoiceId, signal),
    placeholderData: (previous, previousQuery) =>
      previous?.source?.spreadsheet &&
      previousQuery?.queryKey[1] === clientId &&
      previousQuery?.queryKey[2] === period
        ? previous
        : undefined,
    staleTime: 0,
    retry: (count, error) => !(error instanceof ApiError && error.status < 500) && count < 1,
  });
  const returnTo =
    params.origin === "return"
      ? params.returnSection
        ? "/gst/$clientId/$period/sales/sections/$section"
        : "/gst/$clientId/$period/sales"
      : "/gst/$clientId/$period/sales/register";
  const backSearch = {
    filter:
      params.filter === "needs_review" || params.filter === "ready" ? params.filter : undefined,
    q: params.q,
    selected: params.origin === "register" || params.selected ? invoiceId : undefined,
    issue: params.issue,
    buyer: params.buyer,
    returnTask: params.returnTask,
  };
  if (query.isPending)
    return (
      <main className="p-10">
        <p role="status" className="text-sm text-muted-foreground">
          Loading invoice…
        </p>
      </main>
    );
  if (query.isError)
    return (
      <main className="mx-auto max-w-xl space-y-5 px-6 py-20">
        <h1 className="text-2xl font-semibold">Invoice unavailable</h1>
        <p role="alert">{query.error.message}</p>
        <div className="flex gap-4">
          {query.error instanceof ApiError && query.error.status === 401 ? (
            <a href="/users/log_in" className="underline">
              Sign in
            </a>
          ) : (
            <Button variant="outline" onClick={() => query.refetch()}>
              Try again
            </Button>
          )}
          <Button
            variant="ghost"
            nativeButton={false}
            role="link"
            render={
              <Link
                to={returnTo}
                params={{ clientId, period, section: params.returnSection ?? "" }}
                search={backSearch}
              />
            }
          >
            {params.origin === "return" ? "Back to return" : "Back to register"}
          </Button>
        </div>
      </main>
    );
  return (
    <InvoiceReview
      key={`${clientId}/${period}/${query.data.invoice.id}`}
      data={query.data}
      layout={query.data.source?.spreadsheet ? spreadsheetLayout : layout}
      spreadsheetPreferences={spreadsheetPreferences}
      pdfZoom={pdfZoom}
      pdfSession={pdfSession}
      refreshing={query.isFetching}
      transitioning={query.isPlaceholderData}
      refresh={() => query.refetch()}
    />
  );
}

function InvoiceReview({
  data,
  layout,
  spreadsheetPreferences,
  pdfZoom,
  pdfSession,
  refreshing,
  transitioning,
  refresh,
}: {
  data: SalesInvoiceReviewData;
  layout: React.RefObject<Layout>;
  spreadsheetPreferences: React.RefObject<SpreadsheetPreferences>;
  pdfZoom: React.RefObject<number>;
  pdfSession: React.RefObject<PdfSession | null>;
  refreshing: boolean;
  transitioning: boolean;
  refresh: () => unknown;
}) {
  const {
    clientId = "",
    period = "",
    invoiceId = "",
  } = useParams({ from: "/gst/$clientId/$period/sales/invoices/$invoiceId" });
  const params = useSearch({ from: "/gst/$clientId/$period/sales/invoices/$invoiceId" });
  const setParams = useNavigate({ from: "/gst/$clientId/$period/sales/invoices/$invoiceId" });
  const navigate = useNavigate();
  const cache = useQueryClient();
  const [edit, setEdit] = useState<{ section: ReviewChange["section"]; index?: number } | null>(
    null,
  );
  const [dialogOpen, setDialogOpen] = useState(false);
  const [values, setValues] = useState<ReviewValues>({});
  const initialValues = useRef<ReviewValues>({});
  const [confirmation, setConfirmation] = useState<SalesInvoiceReviewData["issues"][number] | null>(
    null,
  );
  const [notice, setNotice] = useState("");
  const opener = useRef<HTMLButtonElement | null>(null);
  const operation = useRef<AbortController | null>(null);
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: ({
      change,
      target,
      controller,
    }: { controller: AbortController } & (
      | { change: ReviewChange; target?: never }
      | { change?: never; target: string }
    )) =>
      change
        ? updateSalesInvoice(clientId, period, invoiceId, change, controller.signal)
        : confirmSalesInvoiceIssue(clientId, period, invoiceId, target, controller.signal),
    onSuccess: async (saved, { change, controller }) => {
      if (controller.signal.aborted) return;
      await cache.cancelQueries({ queryKey: ["sales-review", clientId, period, invoiceId] });
      if (controller.signal.aborted) return;
      cache.setQueryData(["sales-review", clientId, period, invoiceId], saved);
      void cache.invalidateQueries({ queryKey: ["sales"] });
      void cache.invalidateQueries({ queryKey: ["sales-uploads"] });
      void cache.invalidateQueries({ queryKey: ["sales-reports", Number(clientId), period] });
      void cache.invalidateQueries({ queryKey: ["sales-review"], refetchType: "none" });
      setNotice(change ? "Changes saved." : "Decision saved.");
      setDialogOpen(false);
      if (rateRows) restoreEditorFocus();
    },
    onError: (failure, { controller }) => {
      if (
        !controller.signal.aborted &&
        failure instanceof ApiError &&
        [403, 409].includes(failure.status)
      )
        refresh();
    },
    onSettled: (_saved, _failure, { controller }) => {
      if (operation.current === controller) operation.current = null;
    },
  });
  const busy = mutation.isPending || transitioning;
  const error = mutation.error;
  const taskQuery = useQuery({
    queryKey: ["sales-reports", Number(clientId), period],
    enabled: Boolean(params.returnTask),
    retry: false,
    queryFn: async ({ signal }) => {
      const response = await fetch(`/api/workspace/sales/${clientId}/${period}/reports`, {
        signal,
        credentials: "same-origin",
      });
      if (!response.ok) throw new Error("Could not load the selected task.");
      return response.json() as Promise<components["schemas"]["SalesReturnReports"]>;
    },
  });
  const task = taskQuery.data?.tasks.find((item) => item.id === params.returnTask);
  const taskIds = new Set(task?.source_ids ?? []);
  const constrainTaskQueue = Boolean(
    params.returnTask &&
      (params.origin === "register" || params.issue === "report_notes" || task?.kind === "notes"),
  );
  const requestedFilter = params.filter;
  const filter =
    requestedFilter === "ready" || requestedFilter === "needs_review" ? requestedFilter : "all";
  const matchesScope = (item: SalesInvoiceReviewData["queue"][number]) =>
    (!constrainTaskQueue || taskIds.has(item.id)) &&
    (!params.buyer || item.buyer_gstin === params.buyer) &&
    (!params.issue ||
      params.issue === "report_notes" ||
      (item.issue_codes ?? []).includes(params.issue)) &&
    (!params.q ||
      `${item.number} ${item.customer ?? ""} ${item.buyer_gstin ?? ""}`
        .toLowerCase()
        .includes(params.q.trim().toLowerCase()));
  const scopedQueue = data.queue.filter(matchesScope);
  const visible = scopedQueue.filter((item) => filter === "all" || item.status === filter);
  const position = visible.findIndex((item) => item.id === data.invoice.id);
  // Keep the current invoice on screen if a save removes it from the filter.
  // Neighbours still follow its position in the full, server-ordered queue.
  const currentIndex = data.queue.findIndex((item) => item.id === data.invoice.id);
  const matchesFilter = (item: SalesInvoiceReviewData["queue"][number]) =>
    matchesScope(item) && (filter === "all" || item.status === filter);
  const previous = data.queue.slice(0, currentIndex).filter(matchesFilter).at(-1);
  const next = data.queue.slice(currentIndex + 1).find(matchesFilter);
  const positionLabel =
    constrainTaskQueue && !task
      ? taskQuery.isFetching
        ? "Loading selected task…"
        : "Selected task unavailable · return to choose another"
      : position >= 0
        ? `${position + 1} of ${visible.length} ${filter === "needs_review" ? "needing review" : filter === "ready" ? "ready invoices" : "invoices"}`
        : filter === "needs_review" && visible.length === 0
          ? "No invoices need review"
          : `${visible.length} ${filter === "needs_review" ? "still need review" : "in this view"}`;
  const returnTo =
    params.origin === "return"
      ? params.returnSection
        ? "/gst/$clientId/$period/sales/sections/$section"
        : "/gst/$clientId/$period/sales"
      : "/gst/$clientId/$period/sales/register";
  const registerSearch = {
    filter: filter === "all" ? undefined : filter,
    q: params.q,
    selected: params.origin === "register" || params.selected ? invoiceId : undefined,
    issue: params.issue,
    buyer: params.buyer,
    returnTask: params.returnTask,
  };
  const status = data.queue.find((item) => item.id === data.invoice.id)?.status;
  const canEdit = data.can_edit && !refreshing && !busy;
  const fieldErrors = error instanceof ReviewApiError ? error.fields : {};
  const rateRows = data.source?.spreadsheet?.granularity === "invoice_rate_components";
  const inlineEditor = Boolean(rateRows && edit && dialogOpen && !confirmation);
  const activeFields = (edit ? data.editable_fields[edit.section] : []).filter(
    (field) =>
      !rateRows ||
      edit?.section === "facts" ||
      (edit?.section === "totals"
        ? field === "printed_grand_total"
        : [
            "taxable_value",
            "cgst_rate",
            "sgst_rate",
            "igst_rate",
            "cgst_amount",
            "sgst_amount",
            "igst_amount",
          ].includes(field)),
  );
  const needsAttention = data.checks.filter((check) => check.status === "failed").length;
  const openIssues = data.issues.filter((issue) => issue.status === "open");
  const spreadsheet = data.source?.spreadsheet;

  useEffect(() => () => operation.current?.abort(), []);
  useEffect(() => {
    if (inlineEditor)
      document.querySelector<HTMLElement>('[aria-label="Edit invoice values"] input')?.focus();
  }, [inlineEditor, edit]);
  useEffect(() => {
    document.title = `Invoice ${data.invoice.number} · Nila`;
  }, [data.invoice.number]);

  function go(id: string | undefined, selectedFilter = filter) {
    if (!id || busy || dialogOpen) return;
    navigate({
      to: "/gst/$clientId/$period/sales/invoices/$invoiceId",
      params: { clientId, period, invoiceId: id },
      search: {
        ...params,
        filter:
          selectedFilter === "all" ? undefined : salesSearch({ filter: selectedFilter }).filter,
      },
    });
  }
  function changeFilter(value: string) {
    const matching = scopedQueue.filter((item) => value === "all" || item.status === value);
    const currentMatches = matching.some((item) => item.id === data.invoice.id);
    if (!currentMatches && matching.length) go(matching[0].id, value);
    else {
      setParams({
        search: {
          ...params,
          filter: value === "all" ? undefined : salesSearch({ filter: value }).filter,
        },
        resetScroll: false,
      });
    }
  }
  useEffect(() => {
    const keyboard = (event: KeyboardEvent) => {
      const target = event.target;
      if (event.key === "Escape" && inlineEditor && !busy && !navigationShortcutBlocked(event)) {
        event.preventDefault();
        closeInlineEditor();
        return;
      }
      if (
        event.key === "Escape" &&
        !event.altKey &&
        !event.ctrlKey &&
        !event.metaKey &&
        !event.shiftKey &&
        !busy &&
        !dialogOpen &&
        !navigationShortcutBlocked(event)
      ) {
        event.preventDefault();
        navigate({
          to: returnTo,
          params: { clientId, period, section: params.returnSection ?? "" },
          search: registerSearch,
        });
        return;
      }
      if (
        navigationShortcutBlocked(event) ||
        event.shiftKey ||
        busy ||
        dialogOpen ||
        !event.altKey ||
        event.ctrlKey ||
        event.metaKey ||
        (target instanceof HTMLElement &&
          (target.isContentEditable ||
            /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName) ||
            target.closest('[role="dialog"]')))
      )
        return;
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
        event.preventDefault();
        go(event.key === "ArrowLeft" ? previous?.id : next?.id);
      }
    };
    window.addEventListener("keydown", keyboard);
    return () => window.removeEventListener("keydown", keyboard);
  });

  function openEditor(section: ReviewChange["section"], button: HTMLButtonElement, index?: number) {
    opener.current = button;
    const source =
      section === "facts"
        ? data.facts
        : section === "totals"
          ? data.printed_totals
          : (data.lines.find((line) => line.index === index)?.values ?? {});
    const openingValues = Object.fromEntries(
      data.editable_fields[section].map((field) => [field, source[field] ?? ""]),
    );
    initialValues.current = openingValues;
    setValues(openingValues);
    mutation.reset();
    setConfirmation(null);
    setEdit({ section, index });
    setDialogOpen(true);
  }
  function restoreEditorFocus() {
    requestAnimationFrame(() => {
      if (rateRows && edit?.section === "line")
        document
          .querySelector<HTMLButtonElement>(
            `[aria-label="Edit rate component ${(edit.index ?? 0) + 1}"]`,
          )
          ?.focus();
      else opener.current?.focus();
    });
  }
  function closeInlineEditor() {
    setDialogOpen(false);
    restoreEditorFocus();
  }
  function save(event: FormEvent) {
    event.preventDefault();
    if (!canEdit || !dialogOpen || operation.current || (!edit && !confirmation)) return;
    const changes = Object.fromEntries(
      Object.entries(values).filter(([field, value]) => value !== initialValues.current[field]),
    );
    if (edit && !Object.keys(changes).length) {
      if (inlineEditor) closeInlineEditor();
      else setDialogOpen(false);
      return;
    }
    const controller = new AbortController();
    operation.current = controller;
    mutation.mutate(
      edit
        ? {
            change: {
              section: edit.section,
              values: changes,
              ...(edit.index === undefined ? {} : { line_index: edit.index }),
            },
            controller,
          }
        : { target: confirmation!.target, controller },
    );
  }

  const editorForm = (
    <form
      onSubmit={save}
      onKeyDown={(event) => {
        if (event.key === "Escape" && inlineEditor && !busy) {
          event.preventDefault();
          event.stopPropagation();
          closeInlineEditor();
          return;
        }
        if (
          edit &&
          canEdit &&
          event.key === "Enter" &&
          (event.ctrlKey || event.metaKey) &&
          !event.altKey &&
          !event.shiftKey &&
          !event.repeat &&
          !event.nativeEvent.isComposing
        ) {
          event.preventDefault();
          event.currentTarget.requestSubmit();
        }
      }}
      className="space-y-4"
      aria-label="Edit invoice values"
    >
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error.message}
        </p>
      )}
      {!data.can_edit && (
        <p className="text-sm text-muted-foreground">
          {data.lock_reason || "This invoice is read-only."}
        </p>
      )}
      {confirmation ? (
        <p className="text-sm leading-6">{confirmation.message}</p>
      ) : (
        <div className="grid gap-4 sm:grid-cols-2">
          {activeFields.map((field) => {
            const errors =
              fieldErrors[field] ??
              (edit?.index === undefined
                ? undefined
                : fieldErrors[`line_items[${edit.index}].${field}`]);
            const id = `invoice-edit-${field}`;
            return (
              <Field
                data-invalid={Boolean(errors)}
                key={field}
                className={`space-y-2 ${["description", "item_name", "buyer_name", "narration", ...(inlineEditor ? ["taxable_value"] : [])].includes(field) ? "sm:col-span-2" : ""}`}
              >
                <FieldLabel htmlFor={id}>
                  {spreadsheet
                    ? (fieldLabels[field] ?? field).replace(/^Printed /, "Reported ")
                    : (fieldLabels[field] ?? field)}
                </FieldLabel>
                {field === "place_of_supply" ? (
                  <SelectField
                    id={id}
                    value={values[field] ?? ""}
                    disabled={busy || !data.can_edit}
                    onValueChange={(nextValue) =>
                      setValues((previous) => ({ ...previous, [field]: nextValue }))
                    }
                    aria-invalid={Boolean(errors)}
                    aria-describedby={errors ? `${id}-error` : undefined}
                  >
                    <SelectFieldOption value="">Not provided</SelectFieldOption>
                    {values[field] &&
                      !data.states.some((state) => state.value === values[field]) && (
                        <SelectFieldOption value={values[field]}>{values[field]} (current value)</SelectFieldOption>
                      )}
                    {data.states.map((state) => (
                      <SelectFieldOption key={state.value} value={state.value}>
                        {state.label}
                      </SelectFieldOption>
                    ))}
                  </SelectField>
                ) : field === "original_sale_category" ? (
                  <SelectField
                    id={id}
                    value={values[field] ?? ""}
                    disabled={busy || !data.can_edit}
                    onValueChange={(nextValue) =>
                      setValues((previous) => ({ ...previous, [field]: nextValue }))
                    }
                  >
                    <SelectFieldOption value="">Not provided / not applicable</SelectFieldOption>
                    <SelectFieldOption value="b2cs">B2C other / small</SelectFieldOption>
                    <SelectFieldOption value="b2cl">B2C large (interstate)</SelectFieldOption>
                  </SelectField>
                ) : field === "line_amount_tax_inclusion" ? (
                  <SelectField
                    id={id}
                    value={values[field] || "unknown"}
                    disabled={busy || !data.can_edit}
                    onValueChange={(nextValue) =>
                      setValues((previous) => ({ ...previous, [field]: nextValue }))
                    }
                  >
                    <SelectFieldOption value="unknown">Not known</SelectFieldOption>
                    <SelectFieldOption value="inclusive">Includes tax</SelectFieldOption>
                    <SelectFieldOption value="exclusive">Excludes tax</SelectFieldOption>
                  </SelectField>
                ) : (
                  <Input
                    id={id}
                    type={field === "invoice_date" ? "date" : "text"}
                    inputMode={decimalFields.has(field) ? "decimal" : undefined}
                    value={values[field] ?? ""}
                    disabled={busy || !data.can_edit}
                    onChange={(event) =>
                      setValues((previous) => ({ ...previous, [field]: event.target.value }))
                    }
                    aria-invalid={Boolean(errors)}
                    aria-describedby={errors ? `${id}-error` : undefined}
                  />
                )}
                {errors && <FieldError id={`${id}-error`}>{errors.join(". ")}</FieldError>}
              </Field>
            );
          })}
        </div>
      )}
      <div className="flex justify-end gap-2 border-t pt-4">
        <Button
          type="button"
          variant="outline"
          disabled={busy}
          onClick={() => (inlineEditor ? closeInlineEditor() : setDialogOpen(false))}
        >
          Cancel
        </Button>
        <Button type="submit" disabled={!canEdit}>
          {busy
            ? "Saving…"
            : confirmation
              ? confirmation.action_label || "Confirm"
              : "Save changes"}
        </Button>
      </div>
    </form>
  );

  return (
    <main className="flex h-dvh min-h-0 flex-col bg-background">
      <header className="flex min-h-16 shrink-0 flex-wrap items-center justify-between gap-3 border-b px-5 py-3">
        <div className="flex flex-wrap items-center gap-4">
          <Button
            variant="ghost"
            size="sm"
            nativeButton={false}
            role="link"
            render={
              <Link
                to={returnTo}
                params={{ clientId, period, section: params.returnSection ?? "" }}
                search={registerSearch}
              />
            }
            disabled={busy || inlineEditor}
          >
            <ArrowLeft /> {params.origin === "return" ? "Back to return" : "Back to register"}{" "}
            <Kbd aria-hidden="true">Esc</Kbd>
          </Button>
          <ShortcutHelpButton />
          <span className="text-sm text-muted-foreground">
            {data.client.name} ·{" "}
            {new Date(`${data.period}-01T00:00:00Z`).toLocaleDateString("en-IN", {
              month: "long",
              year: "numeric",
              timeZone: "UTC",
            })}
          </span>
        </div>
        <div className="flex flex-wrap items-center gap-3">
          <ToggleGroup
            aria-label="Filter invoices"
            size="sm"
            value={[filter]}
            disabled={busy || inlineEditor}
            onValueChange={(selected) => {
              if (selected[0]) changeFilter(selected[0]);
            }}
          >
            {filters.map((item) => (
              <ToggleGroupItem key={item.value} value={item.value}>
                {item.label}{" "}
                <span className="ml-1 tabular-nums text-muted-foreground">
                  {
                    scopedQueue.filter(
                      (invoice) => item.value === "all" || invoice.status === item.value,
                    ).length
                  }
                </span>
              </ToggleGroupItem>
            ))}
          </ToggleGroup>
          <div className="flex items-center gap-1 border-l pl-3">
            <InvoiceQueue
              items={visible}
              currentId={data.invoice.id}
              onSelect={go}
              disabled={busy || dialogOpen}
            />
          </div>
        </div>
      </header>
      <ResizablePanelGroup
        orientation="horizontal"
        className="min-h-0 flex-1"
        defaultLayout={layout.current}
        onLayoutChanged={(value) => {
          layout.current = value;
        }}
      >
        <ResizablePanel id="source" minSize="25%">
          {spreadsheet ? (
            <SourceSpreadsheet
              source={transitioning ? { ...spreadsheet, selected: [] } : spreadsheet}
              clientId={clientId}
              period={period}
              invoiceId={invoiceId}
              uploadRef={data.upload_ref ?? invoiceId}
              preferences={spreadsheetPreferences}
              disabled={busy || dialogOpen}
            />
          ) : (
            <section
              aria-label="Source document"
              className="flex h-full min-w-0 flex-col bg-muted/40"
            >
              <div className="flex min-h-12 shrink-0 items-center gap-2 border-b bg-background px-4 py-3">
                <FileText className="size-4 shrink-0 text-muted-foreground" />
                <p className="truncate text-sm text-muted-foreground">
                  {data.source?.name ?? "Source document"}
                </p>
              </div>
              <div className="min-h-0 flex-1">
                {data.source?.url ? (
                  <Suspense
                    fallback={
                      <p role="status" className="p-6 text-sm text-muted-foreground">
                        Loading source PDF…
                      </p>
                    }
                  >
                    <SourcePdf
                      url={data.source.url}
                      pages={data.source.pages}
                      images={data.source.images}
                      zoom={pdfZoom}
                      session={pdfSession}
                    />
                  </Suspense>
                ) : data.source?.images.length ? (
                  <div className="h-full space-y-4 overflow-auto p-4">
                    {data.source.images.map((image, index) => (
                      <img
                        key={image}
                        src={image}
                        alt={`Source invoice page ${data.source?.pages[index] ?? index + 1}`}
                        className="w-full"
                      />
                    ))}
                  </div>
                ) : (
                  <div className="flex h-full items-center justify-center p-6 text-center text-sm text-muted-foreground">
                    No source document is available for this invoice.
                  </div>
                )}
              </div>
            </section>
          )}
        </ResizablePanel>
        <ResizableHandle withHandle aria-label="Resize source document" />
        <ResizablePanel id="details" minSize="35%">
          {transitioning ? (
            <p role="status" className="p-5 text-sm text-muted-foreground">
              Loading invoice details…
            </p>
          ) : (
            <section aria-label="Invoice details" className="flex h-full min-h-0 min-w-0 flex-col">
              <div className="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4">
                {!data.can_edit && (
                  <p id="invoice-lock" className="rounded-lg border bg-muted/40 px-4 py-3 text-sm">
                    {data.lock_reason || "Your role allows viewing, not editing this invoice."}
                  </p>
                )}
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <div className="mb-2">
                      <Badge
                        variant="secondary"
                        className={status === "needs_review" ? "bg-amber-50 text-amber-800" : ""}
                      >
                        {status === "ready" ? "Ready" : "Needs review"}
                      </Badge>
                    </div>
                    <h1 className="text-2xl font-semibold tracking-tight">
                      Invoice {data.invoice.number || "Number not provided"}
                    </h1>
                    <p className="mt-1 text-sm text-muted-foreground">
                      {data.invoice.date || "Date not provided"}
                    </p>
                  </div>
                  <div className="flex items-center gap-1">
                    {data.upload_ref && (
                      <SalesRemovalActions
                        key={data.invoice.id}
                        clientId={data.client.id}
                        clientName={data.client.name}
                        period={data.period}
                        batchRef={data.upload_ref}
                        activeIds={[data.invoice.id]}
                        invoiceNumber={data.invoice.number || data.invoice.id}
                        disabled={!canEdit || inlineEditor}
                        afterRemoveUrl={
                          next
                            ? `/gst/${clientId}/${period}/sales/invoices/${encodeURIComponent(next.id)}?filter=${filter}`
                            : `/gst/${clientId}/${period}/sales/register`
                        }
                      />
                    )}
                    <Button
                      variant="ghost"
                      size="icon-sm"
                      aria-label="Edit invoice details"
                      disabled={!canEdit || inlineEditor}
                      aria-describedby={!data.can_edit ? "invoice-lock" : undefined}
                      onClick={(event) => openEditor("facts", event.currentTarget)}
                    >
                      <Pencil />
                    </Button>
                  </div>
                </div>
                <div className="border-b pb-4">
                  <p className="text-sm font-semibold">
                    {data.invoice.buyer_name || "Customer not provided"}
                  </p>
                  <p className="mt-1 text-sm text-muted-foreground">
                    GSTIN {data.invoice.buyer_gstin || "not provided"}
                  </p>
                  <p className="mt-1 text-sm text-muted-foreground">
                    Place of supply: {data.invoice.place_of_supply || "Not determined"}
                  </p>
                  {data.facts.narration && (
                    <p className="mt-2 text-sm text-muted-foreground">{data.facts.narration}</p>
                  )}
                </div>
                {inlineEditor && edit?.section === "facts" && editorForm}
                {rateRows ? (
                  <InvoiceRateDetails
                    data={data}
                    disabled={!canEdit || inlineEditor}
                    editing={inlineEditor ? edit : null}
                    editor={editorForm}
                    onEdit={openEditor}
                  />
                ) : (
                  <>
                    <section aria-label="Invoice lines">
                      <div className="overflow-hidden rounded-lg border">
                        <Table>
                          <TableHeader>
                            <TableRow className="bg-muted/30">
                              <TableHead className="pl-4">
                                {rateRows ? "Tax breakdown" : "Description"}
                              </TableHead>
                              <TableHead className="text-right">Taxable</TableHead>
                              <TableHead className="text-right">GST</TableHead>
                              <TableHead className="w-10">
                                <span className="sr-only">Edit</span>
                              </TableHead>
                            </TableRow>
                          </TableHeader>
                          <TableBody>
                            {data.lines.map((line) => (
                              <TableRow key={line.index}>
                                <TableCell className="py-2 pl-4">
                                  <p className="max-w-72 font-medium whitespace-normal">
                                    {line.values.description ||
                                      line.values.item_name ||
                                      `Line ${line.index + 1}`}
                                  </p>
                                  {!rateRows && (
                                    <p className="mt-1 flex flex-wrap gap-x-3 text-xs text-muted-foreground">
                                      <span>HSN {line.display.hsn_sac || "—"}</span>
                                      <span>
                                        {line.display.quantity || "—"} {line.display.uom} ×{" "}
                                        {line.display.printed_unit_price || "—"}
                                      </span>
                                    </p>
                                  )}
                                </TableCell>
                                <TableCell className="text-right align-top pt-2 tabular-nums">
                                  {line.display.taxable_value || "—"}
                                </TableCell>
                                <TableCell className="text-right align-top pt-2 leading-5 tabular-nums">
                                  {["cgst", "sgst", "igst"]
                                    .filter(
                                      (head) =>
                                        line.values[`${head}_rate`] ||
                                        line.values[`${head}_amount`],
                                    )
                                    .map((head) => (
                                      <p key={head} className="whitespace-nowrap">
                                        <span className="mr-2 text-xs text-muted-foreground">
                                          {head.toUpperCase()} {line.display[`${head}_rate`] || "—"}
                                          %
                                        </span>
                                        {line.display[`${head}_amount`] || "—"}
                                      </p>
                                    ))}
                                </TableCell>
                                <TableCell>
                                  <Button
                                    variant="ghost"
                                    size="icon-xs"
                                    aria-label={`Edit line ${line.index + 1}`}
                                    disabled={!canEdit || inlineEditor}
                                    onClick={(event) =>
                                      openEditor("line", event.currentTarget, line.index)
                                    }
                                  >
                                    <Pencil />
                                  </Button>
                                </TableCell>
                              </TableRow>
                            ))}
                            {data.lines.length === 0 && (
                              <TableRow>
                                <TableCell
                                  colSpan={4}
                                  className="py-8 text-center text-muted-foreground"
                                >
                                  No invoice lines were extracted.
                                </TableCell>
                              </TableRow>
                            )}
                          </TableBody>
                        </Table>
                      </div>
                    </section>
                    <Collapsible
                      render={<section aria-labelledby="invoice-totals" />}
                      defaultOpen={data.totals.some((total) => total.status !== "matches")}
                    >
                      <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
                        <h2 id="invoice-totals" className="text-sm font-semibold">
                          Calculated totals
                        </h2>
                        <Button
                          variant="ghost"
                          size="sm"
                          disabled={!canEdit || inlineEditor}
                          onClick={(event) => openEditor("totals", event.currentTarget)}
                        >
                          <Pencil /> {spreadsheet ? "Edit reported totals" : "Edit printed totals"}
                        </Button>
                      </div>
                      <dl className="mb-2 grid grid-cols-3 gap-3 py-2">
                        {data.totals.map((total) => (
                          <div key={total.field}>
                            <dt className="text-xs text-muted-foreground">{total.label}</dt>
                            <dd className="mt-1 text-sm font-semibold tabular-nums">
                              {total.calculated}
                            </dd>
                          </div>
                        ))}
                      </dl>
                      <CollapsibleTrigger
                        render={<Button variant="ghost" size="sm" className="group mb-2" />}
                      >
                        {spreadsheet ? "Compare with report totals" : "Compare with printed totals"}{" "}
                        <ChevronDown className="group-data-panel-open:rotate-180" />
                      </CollapsibleTrigger>
                      <CollapsibleContent>
                        <div className="overflow-hidden rounded-lg border">
                          <Table>
                            <TableHeader>
                              <TableRow className="bg-muted/30">
                                <TableHead className="pl-4">Total</TableHead>
                                <TableHead className="text-right">From lines</TableHead>
                                <TableHead className="text-right">
                                  {spreadsheet ? "In client’s report" : "Printed on bill"}
                                </TableHead>
                                <TableHead>Comparison</TableHead>
                              </TableRow>
                            </TableHeader>
                            <TableBody>
                              {data.totals.map((total) => (
                                <TableRow key={total.field}>
                                  <TableCell className="pl-4">{total.label}</TableCell>
                                  <TableCell className="text-right tabular-nums">
                                    {total.calculated}
                                  </TableCell>
                                  <TableCell className="text-right tabular-nums">
                                    {total.printed}
                                  </TableCell>
                                  <TableCell>
                                    <span
                                      className={`text-xs ${total.status === "matches" ? "text-emerald-700" : total.status === "mismatch" ? "text-amber-700" : "text-muted-foreground"}`}
                                    >
                                      {total.status === "matches"
                                        ? "Matches"
                                        : total.status === "mismatch"
                                          ? `${total.difference ?? "—"} difference`
                                          : "Not compared"}
                                    </span>
                                  </TableCell>
                                </TableRow>
                              ))}
                            </TableBody>
                          </Table>
                        </div>
                      </CollapsibleContent>
                    </Collapsible>
                  </>
                )}
                {openIssues.length > 0 && (
                  <section aria-label="Needs your review" className="space-y-3">
                    {openIssues
                      .filter((issue) => !rateRows || issue.code !== "grand_total_mismatch")
                      .map((issue) => (
                        <div key={issue.target} className="rounded-lg border px-4 py-3">
                          <p className="text-sm font-medium">{issue.title}</p>
                          <p className="mt-1 text-sm leading-6 text-muted-foreground">
                            {issue.message}
                          </p>
                          {issue.lookup_details && (
                            <Collapsible className="mt-2">
                              <CollapsibleTrigger
                                render={<Button variant="ghost" size="sm" className="group px-0" />}
                              >
                                GST lookup details{" "}
                                <ChevronDown className="group-data-panel-open:rotate-180" />
                              </CollapsibleTrigger>
                              <CollapsibleContent className="pt-1 text-sm leading-6 text-muted-foreground">
                                {issue.lookup_details}
                              </CollapsibleContent>
                            </Collapsible>
                          )}
                          {issue.code === "seller_identity_mismatch" &&
                            data.upload_ref &&
                            canEdit && (
                              <div className="mt-3">
                                <MoveSalesUpload
                                  clientId={data.client.id}
                                  clientName={data.client.name}
                                  period={data.period}
                                  batchRef={data.upload_ref}
                                />
                              </div>
                            )}
                          {issue.can_confirm && (
                            <Button
                              variant="outline"
                              size="sm"
                              className="mt-3"
                              disabled={!canEdit || inlineEditor}
                              onClick={(event) => {
                                opener.current = event.currentTarget;
                                setConfirmation(issue);
                                setEdit(null);
                                mutation.reset();
                                setDialogOpen(true);
                              }}
                            >
                              {issue.action_label || "Confirm"}
                            </Button>
                          )}
                        </div>
                      ))}
                  </section>
                )}
              </div>
              <Collapsible
                render={<footer />}
                className="shrink-0 border-t bg-background px-5 py-3"
              >
                <CollapsibleContent
                  id="invoice-checks"
                  className="mb-4 max-h-72 space-y-3 overflow-y-auto border-b pb-4"
                >
                  {data.checks.map((check, index) => (
                    <div key={`${check.label}-${index}`} className="text-sm">
                      <div className="flex items-start justify-between gap-3">
                        <p className="font-medium">{check.title || check.label}</p>
                        <span
                          className={`shrink-0 text-xs ${check.status === "passed" ? "text-emerald-700" : check.status === "failed" ? "text-amber-700" : "text-muted-foreground"}`}
                        >
                          {check.status === "passed"
                            ? "Passed"
                            : check.status === "failed"
                              ? "Needs review"
                              : "Not checked"}
                        </span>
                      </div>
                      {check.detail && <p className="mt-1 text-muted-foreground">{check.detail}</p>}
                      {check.secondary && (
                        <p className="mt-1 text-muted-foreground">{check.secondary}</p>
                      )}
                      {check.difference && (
                        <p className="mt-1 text-muted-foreground">{check.difference}</p>
                      )}
                    </div>
                  ))}
                  {data.checks.length === 0 && (
                    <p className="text-sm text-muted-foreground">No check results are available.</p>
                  )}
                </CollapsibleContent>
                {notice && (
                  <p role="status" className="mb-3 text-sm text-muted-foreground">
                    {notice}
                  </p>
                )}
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <CollapsibleTrigger
                    render={
                      <Button
                        variant="ghost"
                        className="group h-auto min-h-9 justify-start px-0 text-left"
                      />
                    }
                  >
                    <Check
                      className={needsAttention ? "text-amber-700" : "text-muted-foreground"}
                    />
                    <span>
                      {needsAttention
                        ? `${needsAttention} ${needsAttention === 1 ? "check needs" : "checks need"} review`
                        : "Invoice checks"}
                    </span>
                    <ChevronDown className="group-data-panel-open:rotate-180" />
                  </CollapsibleTrigger>
                  <div className="flex items-center gap-2">
                    <Button
                      variant="outline"
                      aria-label="Previous invoice"
                      title="Previous invoice (Alt+Left)"
                      disabled={!previous || busy || dialogOpen}
                      onClick={() => go(previous?.id)}
                    >
                      <ArrowLeft /> Previous
                    </Button>
                    <Button
                      aria-label="Next invoice"
                      title="Next invoice (Alt+Right)"
                      disabled={!next || busy || dialogOpen}
                      onClick={() => go(next?.id)}
                    >
                      Next <ArrowRight />
                    </Button>
                  </div>
                  <p className="w-full text-right text-xs text-muted-foreground">{positionLabel}</p>
                </div>
              </Collapsible>
            </section>
          )}
        </ResizablePanel>
      </ResizablePanelGroup>
      <Dialog
        open={dialogOpen && !inlineEditor}
        onOpenChange={(open) => {
          if (!open && !busy) setDialogOpen(false);
        }}
      >
        <DialogContent
          finalFocus={opener}
          className="max-h-[90dvh] overflow-y-auto sm:max-w-xl"
          showCloseButton={!busy}
        >
          <DialogHeader>
            <DialogTitle>
              {confirmation
                ? confirmation.title
                : edit?.section === "facts"
                  ? "Edit invoice details"
                  : edit?.section === "totals"
                    ? spreadsheet
                      ? "Edit reported totals"
                      : "Edit printed totals"
                    : `Edit invoice line ${(edit?.index ?? 0) + 1}`}
            </DialogTitle>
            <DialogDescription>
              {confirmation
                ? "This records your decision for this month's working."
                : `Correct the values against the source ${spreadsheet ? "report" : "bill"}. Changes apply wherever this invoice is used.`}
            </DialogDescription>
          </DialogHeader>
          {editorForm}
        </DialogContent>
      </Dialog>
    </main>
  );
}
