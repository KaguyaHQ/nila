import { useEffect, useRef, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useBlocker } from "@tanstack/react-router";
import { ArrowUpRight, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Field, FieldLabel } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { fetchSalesInvoice, updateSalesInvoice } from "@/lib/sales-review-api";
import { urlDestination } from "@/lib/route-url";

function lookupTime(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("en-IN", {
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "Asia/Kolkata",
    timeZoneName: "short",
  }).format(date);
}

export function SalesRecordInspector({
  clientId,
  period,
  invoiceId,
  reviewUrl,
  issue,
  affectedCount,
  onClose,
}: {
  clientId: string;
  period: string;
  invoiceId: string;
  reviewUrl: string;
  issue?: string;
  affectedCount: number;
  onClose: () => void;
}) {
  const cache = useQueryClient();
  const query = useQuery({
    queryKey: ["sales-review", clientId, period, invoiceId],
    queryFn: ({ signal }) => fetchSalesInvoice(clientId, period, invoiceId, signal),
    staleTime: 30_000,
  });
  const [editing, setEditing] = useState(false);
  const [values, setValues] = useState({ buyer_name: "", buyer_gstin: "" });
  const [notice, setNotice] = useState("");
  const operation = useRef<AbortController | null>(null);
  useEffect(() => () => operation.current?.abort(), []);
  const save = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: ({
      controller,
      changes,
    }: {
      controller: AbortController;
      changes: Record<string, string>;
    }) =>
      updateSalesInvoice(
        clientId,
        period,
        invoiceId,
        { section: "facts", values: changes },
        controller.signal,
      ),
    onSuccess: async (saved, { controller }) => {
      if (controller.signal.aborted) return;
      await cache.cancelQueries({
        queryKey: ["sales-review", clientId, period, invoiceId],
        exact: true,
      });
      if (controller.signal.aborted) return;
      cache.setQueryData(["sales-review", clientId, period, invoiceId], saved);
      void cache.invalidateQueries({ queryKey: ["sales"] });
      void cache.invalidateQueries({ queryKey: ["sales-reports"] });
      void cache.invalidateQueries({ queryKey: ["sales-checks"] });
      setEditing(false);
      setNotice("Buyer details saved for this invoice.");
    },
    onSettled: () => {
      operation.current = null;
    },
  });
  const data = query.data;
  const dirty =
    editing &&
    Object.entries(values).some(([field, value]) => value !== String(data?.facts[field] ?? ""));
  useBlocker({
    shouldBlockFn: () =>
      save.isPending || (dirty && !window.confirm("Discard your unsaved buyer changes?")),
    enableBeforeUnload: dirty || save.isPending,
  });
  const issues = data?.issues.filter((item) => item.status !== "resolved") ?? [];
  const ordered = [...issues].sort((a, b) => Number(b.code === issue) - Number(a.code === issue));
  return (
    <aside
      aria-label="Selected invoice"
      className="sticky top-4 max-h-[calc(100vh-2rem)] overflow-y-auto rounded-xl border bg-card"
    >
      <div className="flex items-center justify-between border-b px-5 py-3">
        <h2 className="text-sm font-semibold">Invoice details</h2>
        <Button
          variant="ghost"
          size="icon-sm"
          aria-label="Close invoice details"
          disabled={save.isPending}
          onClick={onClose}
        >
          <X />
        </Button>
      </div>
      <div className="space-y-5 p-5">
        {query.isPending && (
          <div role="status" aria-label="Loading invoice details" className="space-y-3">
            <Skeleton className="h-5 w-48" />
            <Skeleton className="h-20 w-full" />
          </div>
        )}
        {query.isError && (
          <div role="alert">
            <p>{query.error.message}</p>
            <Button variant="outline" onClick={() => void query.refetch()}>
              Try again
            </Button>
          </div>
        )}
        {data && (
          <>
            <div>
              <h3 className="font-semibold">{data.invoice.number}</h3>
              <p className="mt-1 text-sm">{data.invoice.buyer_name}</p>
              <p className="mt-1 text-xs text-muted-foreground">
                {data.invoice.date} · {data.invoice.buyer_gstin || "No GSTIN"}
              </p>
            </div>
            {affectedCount > 1 && (
              <p className="text-sm text-muted-foreground">
                {affectedCount} invoices in this buyer group. Select an invoice in the table to
                inspect it.
              </p>
            )}
            {data.buyer_registration && (
              <section
                className="space-y-2 rounded-lg bg-muted/40 p-3"
                aria-label="GST registration evidence"
              >
                <h4 className="text-sm font-medium">GST registration</h4>
                <p className="text-sm">
                  {data.buyer_registration.trade_name || data.buyer_registration.legal_name}
                </p>
                <p className="text-sm font-medium">
                  {data.buyer_registration.registration_status || "Status unavailable"}
                </p>
                {data.buyer_registration.cancellation_date && (
                  <p className="text-sm">
                    Cancellation effective {data.buyer_registration.cancellation_date}
                  </p>
                )}
                <p className="text-xs text-muted-foreground">{data.buyer_registration.gstin}</p>
                {data.buyer_registration.checked_at && (
                  <p className="text-xs text-muted-foreground">
                    Checked {lookupTime(data.buyer_registration.checked_at)}
                  </p>
                )}
              </section>
            )}
            {ordered.map((item) => (
              <section key={item.target} className="space-y-2 rounded-lg border p-3">
                <h4 className="text-sm font-medium">{item.title}</h4>
                <p className="text-sm text-muted-foreground">{item.message}</p>
                {item.lookup_details && (
                  <p className="border-t pt-2 text-xs text-muted-foreground">
                    {item.lookup_details}
                  </p>
                )}
              </section>
            ))}
            {!issues.length && (
              <p className="text-sm text-muted-foreground">No outstanding invoice checks.</p>
            )}
            <dl className="space-y-2 text-sm">
              {data.totals
                .filter((total) => total.printed && total.printed !== "Not captured")
                .map((total) => (
                  <div key={total.field} className="flex justify-between gap-3">
                    <dt className="text-muted-foreground">{total.label}</dt>
                    <dd className="tabular-nums">{total.printed}</dd>
                  </div>
                ))}
            </dl>
            {data.source && (
              <section className="space-y-2 border-t pt-4">
                <h4 className="text-sm font-medium">Source</h4>
                <p className="text-sm">{data.source.name}</p>
                {data.source.spreadsheet?.selected.map((range, index) => (
                  <p key={index} className="text-xs text-muted-foreground">
                    {range.file} · {range.sheet} · rows {range.rows.join(", ")}
                  </p>
                ))}
                {data.source.url && (
                  <a
                    href={data.source.url}
                    target="_blank"
                    rel="noreferrer"
                    className="text-sm underline underline-offset-4"
                  >
                    Open original file
                  </a>
                )}
              </section>
            )}
            {editing ? (
              <form
                className="space-y-3 border-t pt-4"
                onSubmit={(event) => {
                  event.preventDefault();
                  if (operation.current || save.isPending) return;
                  const changes = Object.fromEntries(
                    Object.entries(values).filter(
                      ([key, value]) => value !== String(data.facts[key] ?? ""),
                    ),
                  );
                  if (!Object.keys(changes).length) {
                    setEditing(false);
                    return;
                  }
                  const controller = new AbortController();
                  operation.current = controller;
                  save.mutate({ changes, controller });
                }}
              >
                <p className="text-sm font-medium">Correct this invoice’s buyer</p>
                {(["buyer_name", "buyer_gstin"] as const)
                  .filter((field) => data.editable_fields.facts.includes(field))
                  .map((field) => (
                    <Field key={field}>
                      <FieldLabel htmlFor={`inspector-${field}`}>
                        {field === "buyer_name" ? "Buyer name" : "Buyer GSTIN"}
                      </FieldLabel>
                      <Input
                        id={`inspector-${field}`}
                        value={values[field]}
                        disabled={save.isPending}
                        onChange={(event) => setValues({ ...values, [field]: event.target.value })}
                      />
                    </Field>
                  ))}
                {save.isError && (
                  <p role="alert" className="text-sm text-destructive">
                    {save.error.message}
                  </p>
                )}
                <div className="flex gap-2">
                  <Button type="submit" size="sm" disabled={save.isPending}>
                    {save.isPending ? "Saving…" : "Save correction"}
                  </Button>
                  <Button
                    type="button"
                    size="sm"
                    variant="outline"
                    disabled={save.isPending}
                    onClick={() => setEditing(false)}
                  >
                    Cancel
                  </Button>
                </div>
              </form>
            ) : (
              data.can_edit &&
              data.editable_fields.facts.some(
                (field) => field === "buyer_name" || field === "buyer_gstin",
              ) && (
                <Button
                  variant="outline"
                  onClick={() => {
                    setValues({
                      buyer_name: String(data.facts.buyer_name ?? ""),
                      buyer_gstin: String(data.facts.buyer_gstin ?? ""),
                    });
                    save.reset();
                    setNotice("");
                    setEditing(true);
                  }}
                >
                  Correct buyer details
                </Button>
              )
            )}
            {notice && (
              <p role="status" className="text-sm">
                {notice}
              </p>
            )}
            {data.lock_reason && (
              <p className="text-sm text-muted-foreground">{data.lock_reason}</p>
            )}
            <Button
              variant="outline"
              className="flex w-fit"
              nativeButton={false}
              role="link"
              render={<Link {...urlDestination(reviewUrl)} />}
              disabled={save.isPending}
            >
              Open full review <ArrowUpRight />
            </Button>
          </>
        )}
      </div>
    </aside>
  );
}

