import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { Link, useBlocker } from "@tanstack/react-router";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { SelectField, SelectFieldOption } from "@/components/ui/select-field";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { components } from "@/lib/generated/workspace";
import type { SalesWorkspace } from "@/lib/sales-api";

type Task = components["schemas"]["SalesReportTask"];
type Row = components["schemas"]["SalesReturnReportRow"];
type States = components["schemas"]["SalesReturnReports"]["states"];
const labels: Record<string, string> = {
  rate: "GST rate",
  hsn_sc: "HSN/SAC",
  uqc: "UQC",
  qty: "Quantity",
  txval: "Taxable value",
  iamt: "IGST",
  camt: "CGST",
  samt: "SGST",
  csamt: "Cess",
  pos: "Place of supply",
  place_of_supply: "Place of supply",
  original_sale_category: "Original sale category",
  doc_num: "Document category",
  from: "First number",
  to: "Last number",
  totnum: "Total documents",
  cancel: "Cancelled",
  net_issue: "Issued",
  number: "Document number",
  date: "Date",
  type: "Source category",
  nature: "Source label",
};
const textFields = new Set([
  "hsn_sc",
  "uqc",
  "pos",
  "place_of_supply",
  "original_sale_category",
  "from",
  "to",
]);
const docTypes = [
  "Invoices for outward supply",
  "Invoices for inward supply from unregistered persons",
  "Revised invoice",
  "Debit note",
  "Credit note",
  "Receipt voucher",
  "Payment voucher",
  "Refund voucher",
  "Delivery challan — job work",
  "Delivery challan — approval",
  "Delivery challan — liquid gas",
  "Other delivery challan",
];
const rowKey = (row: Row) => `${row.source_filename ?? ""}:${row.sheet}:${row.row}`;
const money = (value: number) =>
  value.toLocaleString("en-IN", { style: "currency", currency: "INR" });
async function result<T>(response: Response): Promise<T> {
  const body = await response.json();
  if (!response.ok) throw new Error(body.error || "The correction could not be saved.");
  return body;
}

export function SalesReportChecks({
  data,
  scope = "return",
  section,
  selectedTask,
}: {
  data: SalesWorkspace;

  scope?: "sales" | "return";

  section?: string;

  selectedTask?: string;
}) {
  const [selection, setSelection] = useState(selectedTask ?? "");
  const [dirtyTasks, setDirtyTasks] = useState<Set<string>>(new Set());

  useEffect(() => {
    if (selectedTask) setSelection(selectedTask);
  }, [selectedTask]);

  const path = `/api/workspace/sales/${data.client.id}/${data.period}/reports`;
  const cache = useQueryClient();
  const query = useQuery({
    queryKey: ["sales-reports", data.client.id, data.period],
    queryFn: ({ signal }) =>
      fetch(path, { signal }).then(result<components["schemas"]["SalesReturnReports"]>),
  });
  const seen = useRef(new Map<string, Task>());
  const [failed, setFailed] = useState<string | null>(null);
  const save = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: ({
      task,
      values,
    }: {
      task: Task;
      values: Record<string, unknown>;
      draftKey: string;
    }) =>
      fetch(path, {
        method: "PATCH",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token":
            document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "",
        },
        body: JSON.stringify({
          dump_id: task.dump_id,
          basis: task.basis,
          sheet: task.sheet,
          source_filename: task.source_filename,
          row: task.row,
          source_ids: task.source_ids,
          values,
        }),
      }).then(result),
    onSuccess: async (_result, { draftKey }) => {
      setDirtyTasks((ids) => {
        const next = new Set(ids);
        next.delete(draftKey);
        return next;
      });
      setFailed(null);
      await Promise.all([
        cache.invalidateQueries({ queryKey: ["sales"] }),
        cache.invalidateQueries({ queryKey: ["sales-reports"] }),
        cache.invalidateQueries({ queryKey: ["sales-checks"] }),
        cache.invalidateQueries({ queryKey: ["sales-review"] }),
      ]);
    },
    onError: (_error, { task }) => setFailed(task.id),
  });
  useBlocker({
    shouldBlockFn: () =>
      save.isPending ||
      (dirtyTasks.size > 0 && !window.confirm("Discard your unsaved report changes?")),
    enableBeforeUnload: dirtyTasks.size > 0 || save.isPending,
  });
  if (query.isPending) return <p role="status">Loading report issues…</p>;
  if (query.error) return <p role="alert">{query.error.message}</p>;

  const belongs = (task: Task) => {
    if (task.kind === "invoice") return false;
    const sales = task.kind === "notes";

    if (sales !== (scope === "sales")) return false;

    if (!section) return true;

    const sheet = task.sheet.toLowerCase();

    if (section === "hsn") return sheet.includes("hsn") || task.kind === "reconciliation";

    if (section === "b2cs") return sheet.includes("b2cs") || task.kind === "basis";

    if (section === "documents") return sheet.includes("doc");

    return sheet === section.toLowerCase();
  };

  const tasks = query.data.tasks.filter(belongs);

  for (const task of tasks) seen.current.set(task.id, task);

  const current = new Set(tasks.map((task) => task.id));

  const available = [...seen.current.values()].filter(belongs);

  const active = available.find((task) => task.id === selection) ?? tasks[0] ?? available[0];

  if (!available.length) return null;

  return (
    <div className="space-y-4">
      {available.length > 1 && (
        <label className="block max-w-xl space-y-2 text-sm">
          <span className="font-medium">
            {scope === "sales" ? "Review sales" : "Review return section"}
          </span>
          <SelectField
            aria-label={scope === "sales" ? "Review sales" : "Review return section"}
            value={active?.id ?? ""}
            onValueChange={(nextValue) => setSelection(nextValue)}
          >
            {available.map((task) => (
              <SelectFieldOption key={task.id} value={task.id}>
                {task.title}
                {current.has(task.id) ? "" : " — Saved"}
              </SelectFieldOption>
            ))}
          </SelectField>
        </label>
      )}
      <p role="status" className="text-sm text-muted-foreground">
        {current.size
          ? `${current.size} ${current.size === 1 ? "check remains" : "checks remain"}.`
          : "Changes saved. No checks remain in this section."}
      </p>
      {available.map((task) => (
        <div key={task.id} hidden={task.id !== active?.id}>
          <ReportTask
            task={task}
            onDirty={(formKey) =>
              setDirtyTasks((ids) => new Set([...ids, `${task.id}/${formKey}`]))
            }
            scope={scope}
            returnSection={section}
            data={data}
            states={query.data.states}
            resolved={!current.has(task.id)}
            disabled={
              !query.data.editable || save.isPending || query.isFetching || failed === task.id
            }
            error={failed === task.id ? save.error?.message : undefined}
            onRefresh={async () => {
              const refreshed = await query.refetch();
              if (refreshed.error) return null;
              setFailed(null);
              save.reset();
              return refreshed.data?.tasks.find((item) => item.id === task.id)?.basis ?? null;
            }}
            onSave={(values, reviewedBasis, row) => {
              if (!save.isPending)
                save.mutate({
                  draftKey: `${task.id}/${row ? rowKey(row) : "main"}`,
                  task: {
                    ...task,
                    basis: reviewedBasis,

                    ...(row
                      ? {
                          sheet: row.sheet,
                          row: row.row,
                          source_filename: row.source_filename,
                          source_ids: [],
                        }
                      : {}),
                  },
                  values,
                });
            }}
          />
        </div>
      ))}
    </div>
  );
}

function ReportTask({
  task,
  scope,
  returnSection,
  data,
  states,
  resolved,
  disabled,
  error,
  onSave,
  onRefresh,
  onDirty,
}: {
  task: Task;
  scope: "sales" | "return";
  returnSection?: string;
  data: SalesWorkspace;
  states: States;
  resolved: boolean;
  disabled: boolean;
  error?: string;
  onSave: (values: Record<string, unknown>, reviewedBasis: string, row?: Row) => void;
  onRefresh: () => Promise<string | null>;
  onDirty: (key: string) => void;
}) {
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(task.fields.map((field) => [field, String(task.values[field] ?? "")])),
  );
  const [basis, setBasis] = useState("");
  const [reviewedBasis, setReviewedBasis] = useState(task.basis);
  const dirty = useRef(false);
  useEffect(() => {
    if (!dirty.current) {
      setReviewedBasis(task.basis);
      setValues(
        Object.fromEntries(task.fields.map((field) => [field, String(task.values[field] ?? "")])),
      );
    }
  }, [task]);
  const section = useRef<HTMLElement>(null);
  useEffect(() => {
    if (resolved) section.current?.focus({ preventScroll: true });
  }, [resolved]);
  return (
    <section
      onChangeCapture={(event) => {
        dirty.current = true;
        onDirty((event.target as HTMLElement).closest("form")?.dataset.draftKey ?? "main");
      }}
      ref={section}
      tabIndex={-1}
      aria-label={task.title}
      className="space-y-3 rounded-xl border bg-card p-5 outline-none"
    >
      <div className="flex justify-between gap-3">
        <h2 className="text-sm font-semibold">{task.title}</h2>
        {resolved && <span className="text-sm text-muted-foreground">Saved</span>}
      </div>
      {!resolved && (
        <>
          <p className="text-sm text-muted-foreground">{task.message}</p>
          {task.kind === "uploads" ? (
            <Link
              to="/gst/$clientId/$period/sales/uploads"
              params={{ clientId: String(data.client.id), period: data.period }}
              className="text-sm underline"
            >
              Review uploads
            </Link>
          ) : task.kind === "invoice" ? (
            <Link
              to="/gst/$clientId/$period/sales/invoices/$invoiceId"
              params={{
                clientId: String(data.client.id),
                period: data.period,
                invoiceId: task.source_ids[0],
              }}
              search={{
                origin: scope === "return" ? "return" : "register",
                returnTask: task.id,
                returnSection,
              }}
              className="text-sm underline"
            >
              Open invoice
            </Link>
          ) : (
            <form
              className="space-y-3"
              onSubmit={(event) => {
                event.preventDefault();
                if (disabled) return;
                onSave(
                  task.kind === "basis"
                    ? { b2cs_before_notes: basis === "true" }
                    : Object.fromEntries(
                        task.fields.map((field) => [
                          field,
                          textFields.has(field) ? values[field] : Number(values[field]),
                        ]),
                      ),
                  reviewedBasis,
                );
              }}
            >
              {task.kind === "basis" && task.amounts && (
                <>
                  <dl className="grid gap-3 text-sm sm:grid-cols-3">
                    <div>
                      <dt>Supplied taxable sales</dt>
                      <dd className="mt-1 font-medium">{money(task.amounts.before)}</dd>
                    </div>
                    <div>
                      <dt>Net credit notes</dt>
                      <dd className="mt-1 font-medium">{money(task.amounts.notes)}</dd>
                    </div>
                    <div>
                      <dt>After deducting notes</dt>
                      <dd className="mt-1 font-medium">{money(task.amounts.after)}</dd>
                    </div>
                  </dl>
                  <label className="block max-w-md space-y-1 text-sm">
                    <span>B2CS totals in the file</span>
                    <SelectField
                      required
                      disabled={disabled}
                      value={basis}
                      onValueChange={(nextValue) => setBasis(nextValue)}
                    >
                      <SelectFieldOption value="">Choose treatment</SelectFieldOption>
                      <SelectFieldOption value="true">Before notes — deduct them</SelectFieldOption>
                      <SelectFieldOption value="false">Already includes notes — keep totals</SelectFieldOption>
                    </SelectField>
                  </label>
                </>
              )}
              <div className="flex flex-wrap items-end gap-3">
                {task.fields
                  .filter((field) => field !== "b2cs_before_notes")
                  .map((field) => (
                    <label key={field} className="block w-52 space-y-1 text-sm">
                      <span>{labels[field] || field}</span>
                      {field === "pos" || field === "place_of_supply" ? (
                        <SelectField
                          required
                          disabled={disabled}
                          value={values[field] ?? ""}
                          onValueChange={(nextValue) =>
                            setValues({ ...values, [field]: nextValue })
                          }
                        >
                          <SelectFieldOption value="">Choose state</SelectFieldOption>
                          {states.map((state) => (
                            <SelectFieldOption key={state.value} value={state.value}>
                              {state.label}
                            </SelectFieldOption>
                          ))}
                        </SelectField>
                      ) : field === "doc_num" || field === "original_sale_category" ? (
                        <SelectField
                          required
                          disabled={disabled}
                          value={values[field] ?? ""}
                          onValueChange={(nextValue) =>
                            setValues({ ...values, [field]: nextValue })
                          }
                        >
                          <SelectFieldOption value="">Choose</SelectFieldOption>
                          {field === "doc_num" ? (
                            docTypes.map((label, index) => (
                              <SelectFieldOption key={label} value={index + 1}>
                                {label}
                              </SelectFieldOption>
                            ))
                          ) : (
                            <>
                              <SelectFieldOption value="b2cs">B2C (others)</SelectFieldOption>
                              <SelectFieldOption value="b2cl">B2CL</SelectFieldOption>
                            </>
                          )}
                        </SelectField>
                      ) : (
                        <Input
                          required
                          disabled={disabled}
                          type={textFields.has(field) ? "text" : "number"}
                          step="any"
                          value={values[field] ?? ""}
                          placeholder={
                            field.includes("pos") || field === "place_of_supply"
                              ? "State code, e.g. 33"
                              : undefined
                          }
                          onChange={(event) =>
                            setValues({ ...values, [field]: event.target.value })
                          }
                        />
                      )}
                    </label>
                  ))}
                {task.kind !== "reconciliation" && (
                  <Button disabled={disabled} type="submit">
                    {task.kind === "notes" ? `Save for ${task.source_ids.length} notes` : "Save"}
                  </Button>
                )}
              </div>
            </form>
          )}
          <SourceRows rows={task.rows} filename={task.source_filename || task.filename} />
          {task.kind === "notes" && (
            <details>
              <summary className="cursor-pointer text-sm underline">Edit notes separately</summary>
              <ul className="mt-2 space-y-2 text-sm">
                {task.rows
                  .filter(
                    (row, index, rows) =>
                      row.source_id &&
                      rows.findIndex((other) => other.source_id === row.source_id) === index,
                  )
                  .map((row) => (
                    <li key={row.source_id}>
                      <Link
                        to="/gst/$clientId/$period/sales/invoices/$invoiceId"
                        params={{
                          clientId: String(data.client.id),
                          period: data.period,
                          invoiceId: row.source_id!,
                        }}
                        search={{
                          origin: scope === "return" ? "return" : "register",
                          returnTask: task.id,
                          returnSection,
                        }}
                        className="underline"
                      >
                        {String(row.values.number ?? row.source_id)}
                      </Link>
                    </li>
                  ))}
              </ul>
            </details>
          )}
          {task.kind === "reconciliation" && (
            <div className="space-y-3">
              {task.rows.map((row) => (
                <details key={`${row.source_filename}:${row.sheet}:${row.row}`}>
                  <summary className="cursor-pointer text-sm underline">
                    Edit {row.source_filename ? `${row.source_filename} · ` : ""}
                    {row.sheet}, row {row.row}
                  </summary>
                  <SummaryCorrection
                    row={row}
                    disabled={disabled}
                    onSave={(values) => onSave(values, reviewedBasis, row)}
                  />
                </details>
              ))}
            </div>
          )}
          {error && (
            <div role="alert" className="space-y-2 text-sm text-destructive">
              <p>{error}</p>
              <Button
                variant="outline"
                type="button"
                onClick={async () => {
                  const updated = await onRefresh();
                  if (updated) setReviewedBasis(updated);
                }}
              >
                Refresh and review again
              </Button>
            </div>
          )}
        </>
      )}
    </section>
  );
}

function SourceRows({ rows, filename }: { rows: Row[]; filename: string }) {
  if (!rows.length) return null;
  const relevant =
    rows[0].section === "doc_issue"
      ? ["nature", "from", "to", "totnum", "cancel", "net_issue"]
      : rows[0].section.startsWith("hsn")
        ? ["hsn_sc", "rate", "txval", "iamt", "camt", "samt"]
        : ["number", "pos", "type", "rate", "txval", "iamt", "camt", "samt"];
  return (
    <div className="space-y-2">
      <p className="text-xs text-muted-foreground">{filename} · Relevant source columns</p>
      <div className="max-h-64 overflow-auto">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Source row</TableHead>
              {relevant.map((field) => (
                <TableHead key={field}>
                  {rows[0].headers?.[rows[0].columns?.[field] ?? ""] ?? labels[field] ?? field}
                </TableHead>
              ))}
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map((row) => (
              <TableRow key={`${row.source_filename}:${row.sheet}:${row.row}`}>
                <TableCell>
                  {row.source_filename && (
                    <div className="text-xs text-muted-foreground">{row.source_filename}</div>
                  )}
                  {row.sheet} · {row.row}
                </TableCell>
                {relevant.map((field) => (
                  <TableCell key={field}>
                    {String((row.source_values ?? row.values)[field] ?? "—")}
                  </TableCell>
                ))}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </div>
      <details>
        <summary className="cursor-pointer text-xs underline">
          Show full {rows.length === 1 ? "row" : "rows"}
        </summary>
        {rows.map((row) => (
          <div key={`${row.source_filename}:${row.sheet}:${row.row}`} className="mt-3">
            <p className="text-xs">
              {row.source_filename || filename} · {row.sheet} · row {row.row}
            </p>
            <Table>
              <TableHeader>
                <TableRow>
                  {Object.keys(row.cells ?? {}).map((col) => (
                    <TableHead key={col}>{row.headers?.[col] ?? col}</TableHead>
                  ))}
                </TableRow>
              </TableHeader>
              <TableBody>
                <TableRow>
                  {Object.values(row.cells ?? {}).map((value, index) => (
                    <TableCell key={index}>{value === "" ? "—" : (value ?? "—")}</TableCell>
                  ))}
                </TableRow>
              </TableBody>
            </Table>
          </div>
        ))}
      </details>
    </div>
  );
}

function SummaryCorrection({
  row,
  disabled,
  onSave,
}: {
  row: Row;
  disabled: boolean;
  onSave: (values: Record<string, unknown>) => void;
}) {
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(
      ["txval", "iamt", "camt", "samt", "csamt"].map((field) => [
        field,
        String(row.values[field] ?? ""),
      ]),
    ),
  );
  return (
    <form
      data-draft-key={rowKey(row)}
      className="mt-3 flex flex-wrap items-end gap-2"
      onSubmit={(event) => {
        event.preventDefault();
        if (!disabled)
          onSave(
            Object.fromEntries(Object.entries(values).map(([key, value]) => [key, Number(value)])),
          );
      }}
    >
      {Object.keys(values).map((field) => (
        <label className="w-32 text-sm" key={field}>
          {labels[field]}
          <Input
            type="number"
            step="any"
            required
            disabled={disabled}
            value={values[field]}
            onChange={(event) => setValues({ ...values, [field]: event.target.value })}
          />
        </label>
      ))}
      <Button disabled={disabled}>Save</Button>
    </form>
  );
}
