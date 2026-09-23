import { RecordTableLink, RecordTableRow } from "@/components/record-table-row";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
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
import { Textarea } from "@/components/ui/textarea";
import {
  fetchPurchaseReview,
  PurchaseReviewError,
  saveBulkPurchaseTreatment,
  type PurchaseReviewData,
} from "@/lib/purchase-review-api";
import { purchaseSearch, stringifySearch } from "@/lib/route-search";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useNavigate, useSearch } from "@tanstack/react-router";
import { Search } from "lucide-react";
import { useEffect, useMemo, useRef, useState } from "react";

const treatmentLabels: Record<string, string> = {
  claim: "Claim this month",
  later: "Claim later",
  exclude: "Do not claim",
  split: "Split treatment",
};
export function PurchaseWorklist({
  client,
  period,
  portalAvailable,
}: {
  client: number;
  period: string;
  portalAvailable: boolean;
}) {
  const params = useSearch({ from: "/gst/$clientId/$period/purchases" });
  const setParams = useNavigate({ from: "/gst/$clientId/$period/purchases/" });
  const filter = params.work ?? "all";
  const search = params.q ?? "";
  const cache = useQueryClient();
  const queryKey = ["purchase-review", String(client), period, "", "all", ""];
  const query = useQuery({
    queryKey,
    queryFn: ({ signal }) => fetchPurchaseReview(String(client), period, "", "all", "", signal),
    retry: false,
  });
  const [selected, setSelected] = useState<number[]>([]);
  const [snapshot, setSnapshot] = useState<PurchaseReviewData["cases"] | null>(null);
  const [choice, setChoice] = useState("later");
  const [reason, setReason] = useState("");
  const [note, setNote] = useState("");
  const [saved, setSaved] = useState("");
  const operation = useRef<AbortController | null>(null);
  useEffect(() => () => operation.current?.abort(), []);
  const data = query.data;
  useEffect(() => {
    if (!snapshot) setSelected([]);
  }, [query.dataUpdatedAt]);
  const rows = useMemo(
    () =>
      (data?.queue ?? []).filter((row) => {
        const lines = (data?.cases ?? []).filter((line) => row.case_ids.includes(line.id));
        const match =
          filter === "all" ||
          (filter === "undecided" &&
            lines.some((line) => !line.values.choice || row.treatment_stale)) ||
          (filter === "missing" && lines.some((line) => line.can_record_document)) ||
          (filter === "differences" &&
            ["possible", "mismatch", "books_only", "2b_only"].includes(row.bucket) &&
            (data?.books_available || row.bucket === "books_only"));
        return match && `${row.number} ${row.vendor}`.toLowerCase().includes(search.toLowerCase());
      }),
    [data, filter, search],
  );
  function eligible(row: PurchaseReviewData["queue"][number]) {
    const lines = (data?.cases ?? []).filter((line) => row.case_ids.includes(line.id));
    return (
      row.bulk_eligible &&
      lines.length === 1 &&
      lines.every((line) => line.available && !line.cess_issue)
    );
  }
  const visibleIds = [...new Set(rows.filter(eligible).flatMap((row) => row.case_ids))];
  const selectedLines = (data?.cases ?? []).filter((line) => selected.includes(line.id));
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: async () => {
      if (!snapshot || operation.current) throw new Error("A save is already in progress.");
      const controller = new AbortController();
      operation.current = controller;
      try {
        return await saveBulkPurchaseTreatment(
          String(client),
          period,
          {
            case_ids: snapshot.map((line) => line.id),
            basis: Object.fromEntries(snapshot.map((line) => [line.id, line.basis])),
            values: {
              choice: choice as "claim" | "later" | "exclude",
              later_reason: choice === "later" ? reason : "",
              exclude_reason: choice === "exclude" ? reason : "",
              note,
            },
          },
          controller.signal,
        );
      } finally {
        if (operation.current === controller) operation.current = null;
      }
    },
    onSuccess: async (fresh) => {
      await cache.cancelQueries({ queryKey: ["purchase-review", String(client), period] });
      cache.setQueryData(queryKey, fresh);
      setSaved(
        `Treatment saved for ${snapshot?.length} ${snapshot?.length === 1 ? "invoice" : "invoices"}.`,
      );
      setSnapshot(null);
      setSelected([]);
      await cache.invalidateQueries({ queryKey: ["purchases"] });
      await cache.invalidateQueries({
        queryKey: ["purchase-review", String(client), period],
        refetchType: "none",
      });
    },
  });
  const needsRefresh =
    mutation.error instanceof PurchaseReviewError &&
    [403, 404, 409].includes(mutation.error.status);
  function change(key: "work" | "q", value: string) {
    setSelected([]);
    setParams({
      search: {
        ...params,
        ...(key === "work"
          ? { work: purchaseSearch({ work: value }).work }
          : { q: value || undefined }),
      },
      resetScroll: false,
      replace: true,
    });
  }
  function open() {
    if (!selectedLines.length || selectedLines.length !== selected.length) return;
    setSnapshot(structuredClone(selectedLines));
    setChoice("later");
    setReason("");
    setNote("");
    mutation.reset();
    setSaved("");
  }
  return (
    <section aria-label="Purchase worklist" className="space-y-3">
      <div className="flex items-center justify-between gap-4">
        <h2 className="font-semibold">Purchases to review</h2>
        <div className="flex gap-3">
          <NativeSelect
            aria-label="Filter purchases"
            value={filter}
            onChange={(e) => change("work", e.target.value)}
          >
            <option value="all">All purchases</option>
            <option value="undecided">Not decided yet</option>
            <option value="missing">Invoice not confirmed</option>
            <option value="differences">Differences</option>
          </NativeSelect>
          <div className="relative">
            <Search className="absolute left-3 top-2.5 size-4 text-muted-foreground" />
            <Input
              className="w-72 pl-9"
              aria-label="Search purchases"
              data-shortcut-search
              placeholder="Search supplier or invoice"
              value={search}
              onChange={(e) => change("q", e.target.value)}
            />
          </div>
        </div>
      </div>
      {data && !data.books_available && portalAvailable && (
        <div className="flex items-center justify-between gap-4 text-sm">
          <p className="text-muted-foreground">
            Showing GSTR-2B documents. Purchase register not imported.
          </p>
        </div>
      )}
      {saved && (
        <p role="status" className="text-sm">
          {saved}
        </p>
      )}
      {query.isError ? (
        <div role="alert">
          {query.error.message}{" "}
          <Button variant="outline" onClick={() => query.refetch()}>
            Try again
          </Button>
        </div>
      ) : query.isPending ? (
        <p role="status">Loading purchase list…</p>
      ) : (
        <div className="rounded-lg border bg-card overflow-hidden [&>[data-slot=table-container]]:max-h-[52vh]">
          <Table>
            <TableHeader className="sticky top-0 z-10 bg-card">
              <TableRow>
                <TableHead className="w-10">
                  <Checkbox
                    aria-label="Select eligible invoices"
                    checked={
                      visibleIds.length > 0 && visibleIds.every((id) => selected.includes(id))
                    }
                    indeterminate={
                      selected.length > 0 && !visibleIds.every((id) => selected.includes(id))
                    }
                    disabled={!visibleIds.length}
                    onCheckedChange={(checked) => setSelected(checked ? visibleIds : [])}
                  />
                </TableHead>
                <TableHead>Invoice / supplier</TableHead>
                <TableHead className="text-right">GST</TableHead>
                {data?.books_available && <TableHead>Comparison</TableHead>}
                <TableHead>ITC decision</TableHead>
                <TableHead className="w-20" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => {
                const lines = (data?.cases ?? []).filter((line) => row.case_ids.includes(line.id));
                const decisions = [
                  ...new Set(
                    lines.map((line) =>
                      line.values.choice ? treatmentLabels[line.values.choice] : "Not decided yet",
                    ),
                  ),
                ];
                return (
                  <RecordTableRow key={row.id}>
                    <TableCell>
                      <Checkbox
                        aria-label={`Select ${row.number}`}
                        disabled={!eligible(row)}
                        checked={
                          row.case_ids.length > 0 &&
                          row.case_ids.every((id) => selected.includes(id))
                        }
                        onCheckedChange={(checked) =>
                          setSelected((current) =>
                            checked
                              ? [...new Set([...current, ...row.case_ids])]
                              : current.filter((id) => !row.case_ids.includes(id)),
                          )
                        }
                      />
                    </TableCell>
                    <TableCell>
                      <p className="font-medium">{row.number}</p>
                      <p className="text-sm text-muted-foreground">{row.vendor}</p>
                      {row.origin_period && (
                        <p className="text-xs text-muted-foreground">
                          From{" "}
                          {new Intl.DateTimeFormat("en-IN", {
                            month: "long",
                            year: "numeric",
                          }).format(new Date(`${row.origin_period}-01T00:00:00`))}{" "}
                          · carried forward
                        </p>
                      )}
                    </TableCell>
                    <TableCell className="text-right tabular-nums">{row.tax}</TableCell>
                    {data?.books_available && <TableCell>{row.status}</TableCell>}
                    <TableCell>
                      {row.treatment_stale ? (
                        <Badge variant="outline">Review again</Badge>
                      ) : (
                        decisions.join(" · ") || "No editable ITC"
                      )}
                    </TableCell>
                    <TableCell>
                      <RecordTableLink
                        to="/gst/$clientId/$period/purchases/review/$itemId"
                        params={{ clientId: String(client), period, itemId: row.id }}
                        search={{
                          filter: "all",
                          return_to: `/gst/${client}/${period}/purchases${stringifySearch(params)}`,
                        }}
                        className="text-sm underline underline-offset-4"
                      >
                        Review
                      </RecordTableLink>
                    </TableCell>
                  </RecordTableRow>
                );
              })}
              {!rows.length && (
                <TableRow>
                  <TableCell
                    colSpan={data?.books_available ? 6 : 5}
                    className="py-10 text-center text-muted-foreground"
                  >
                    {data?.queue.length
                      ? "No purchases match these filters."
                      : "Fetch GSTR-2B to begin."}
                  </TableCell>
                </TableRow>
              )}
            </TableBody>
          </Table>
          <div className="border-t px-4 py-3 text-sm text-muted-foreground">
            {rows.length} review items
            {selected.length > 0 && (
              <span className="ml-4 text-foreground">{selected.length} invoices selected</span>
            )}
          </div>
        </div>
      )}
      {selected.length > 0 && (
        <div className="sticky bottom-4 flex justify-between items-center rounded-lg border bg-background p-4 shadow-sm">
          <p className="text-sm">{selected.length} invoices selected</p>
          <div className="flex gap-2">
            <Button variant="ghost" onClick={() => setSelected([])}>
              Clear selection
            </Button>
            <Button onClick={open}>Set ITC treatment</Button>
          </div>
        </div>
      )}
      <Dialog
        open={snapshot !== null}
        onOpenChange={(open) => {
          if (!open && !mutation.isPending) {
            setSnapshot(null);
            if (mutation.error) {
              setSelected([]);
              void query.refetch();
            }
          }
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Treat {snapshot?.length} invoices</DialogTitle>
            <DialogDescription>
              Applies the same decision to the selected invoices. Nothing changes until saved.
            </DialogDescription>
          </DialogHeader>
          <form
            className="space-y-4"
            onSubmit={(e) => {
              e.preventDefault();
              if (!mutation.isPending && !operation.current) mutation.mutate();
            }}
          >
            {mutation.error && (
              <p role="alert" className="text-sm text-destructive">
                {mutation.error.message}
              </p>
            )}
            <label className="block space-y-2 text-sm">
              Treatment
              <NativeSelect
                aria-label="Treatment"
                value={choice}
                disabled={mutation.isPending}
                onChange={(e) => {
                  setChoice(e.target.value);
                  setReason("");
                }}
              >
                <option value="claim" disabled={snapshot?.some((line) => !line.claimable)}>
                  Claim this month
                </option>
                <option value="later">Claim later</option>
                <option value="exclude">Do not claim</option>
              </NativeSelect>
            </label>
            {snapshot?.some((line) => !line.claimable) && (
              <p className="text-sm text-muted-foreground">
                Some selected invoices need individual checks before they can be claimed.
              </p>
            )}
            {choice !== "claim" && (
              <>
                <label className="block space-y-2 text-sm">
                  Reason
                  <NativeSelect
                    aria-label="Reason"
                    required
                    value={reason}
                    disabled={mutation.isPending}
                    onChange={(e) => setReason(e.target.value)}
                  >
                    <option value="">Choose a reason</option>
                    {data?.reasons[choice as "later" | "exclude"].map((r) => (
                      <option key={r.id} value={r.id}>
                        {r.label}
                      </option>
                    ))}
                  </NativeSelect>
                </label>
                <label className="block space-y-2 text-sm">
                  Note
                  <Textarea
                    value={note}
                    maxLength={1000}
                    required={reason === "other"}
                    disabled={mutation.isPending}
                    onChange={(e) => setNote(e.target.value)}
                  />
                </label>
              </>
            )}
            <div className="flex justify-end gap-2">
              <Button
                type="button"
                variant="ghost"
                disabled={mutation.isPending}
                onClick={() => {
                  setSnapshot(null);
                  if (mutation.error) {
                    setSelected([]);
                    void query.refetch();
                  }
                }}
              >
                Cancel
              </Button>
              <Button type="submit" disabled={mutation.isPending || needsRefresh}>
                {mutation.isPending ? "Saving…" : "Save treatment"}
              </Button>
            </div>
            {needsRefresh && (
              <p className="text-sm text-muted-foreground">
                Close this dialog and review the current invoices before trying again.
              </p>
            )}
          </form>
        </DialogContent>
      </Dialog>
    </section>
  );
}
