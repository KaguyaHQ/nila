import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ArrowLeft, ChevronLeft, ChevronRight, ExternalLink } from "lucide-react";
import { ShortcutHelpButton, navigationShortcutBlocked } from "@/components/keyboard-shortcuts";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group";
import { NativeSelect } from "@/components/ui/native-select";
import { Badge } from "@/components/ui/badge";
import { PurchaseSourceActions } from "@/components/purchase-source-actions";
import { Skeleton } from "@/components/ui/skeleton";
import {
  Table,
  TableHeader,
  TableHead,
  TableBody,
  TableRow,
  TableCell,
} from "@/components/ui/table";
import {
  fetchPurchaseReview,
  savePurchaseTreatment,
  recordPurchaseDocument,
  PurchaseReviewError,
  type PurchaseReviewData,
  type TreatmentValues,
  type TreatmentChoice,
} from "@/lib/purchase-review-api";

const choices: { id: TreatmentChoice; label: string }[] = [
  { id: "claim", label: "Claim this month" },
  { id: "later", label: "Claim later" },
  { id: "exclude", label: "Do not claim" },
  { id: "split", label: "Split treatment" },
];
const blankValues = (): TreatmentValues => ({
  choice: null,
  later_reason: "",
  exclude_reason: "",
  note: "",
  split: {
    claim: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" },
    later: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" },
    exclude: { cgst: "0.00", sgst: "0.00", igst: "0.00", cess: "0.00" },
  },
});

export default function PurchaseReview() {
  const { clientId = "", period = "", itemId = "" } = useParams();
  const [params] = useSearchParams();
  const filter = params.get("filter") ?? "needs_review";
  const q = (params.get("q") ?? "").slice(0, 200);
  const queryKey = ["purchase-review", clientId, period, itemId, filter, q];
  const query = useQuery({
    queryKey,
    queryFn: ({ signal }) => fetchPurchaseReview(clientId, period, itemId, filter, q, signal),
    placeholderData: (previous) =>
      previous?.client.id === Number(clientId) && previous.period === period ? previous : undefined,
    staleTime: 15_000,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false,
    retry: false,
  });
  const back = `/gst/${clientId}/${period}/purchases`;
  if (query.isPending)
    return (
      <main className="p-10">
        <p role="status">Loading purchase review…</p>
      </main>
    );
  if (query.isError)
    return (
      <main className="mx-auto max-w-xl space-y-5 px-6 py-20">
        <h1 className="text-2xl font-semibold">Purchase review unavailable</h1>
        <p role="alert">{query.error.message}</p>
        <Button onClick={() => query.refetch()}>Try again</Button>
        <Link to={back} className="ml-4 underline">
          Back to purchases
        </Link>
      </main>
    );
  return (
    <Review
      key={`${clientId}/${period}`}
      loading={query.isPlaceholderData}
      selectedId={itemId || query.data.item?.id || ""}
      data={query.data}
      queryKey={queryKey}
      refreshing={query.isFetching}
      refresh={() => query.refetch()}
    />
  );
}

function Review({
  data,
  queryKey,
  refreshing,
  loading,
  selectedId,
  refresh,
}: {
  data: PurchaseReviewData;
  queryKey: string[];
  refreshing: boolean;
  loading: boolean;
  selectedId: string;
  refresh: () => Promise<unknown>;
}) {
  const navigate = useNavigate();
  const cache = useQueryClient();
  const [params] = useSearchParams();
  const [search, setSearch] = useState(data.q);
  const routeQuery = params.get("q") ?? "";
  const queueRef = useRef<HTMLElement>(null);
  const [editorRevision, setEditorRevision] = useState("");
  const [resetVersion, setResetVersion] = useState(0);
  const [values, setValues] = useState<TreatmentValues>(blankValues);
  const [saved, setSaved] = useState("");
  const [sourceEditing, setSourceEditing] = useState(false);

  const operation = useRef<AbortController | null>(null);
  const openingCases = useRef<PurchaseReviewData["cases"]>([]);
  const base = `/gst/${data.client.id}/${data.period}/purchases`;
  const returnTo = params.get("return_to");
  const backTo = returnTo === base || returnTo?.startsWith(`${base}?`) ? returnTo : base;
  const item = data.item;
  const position = data.queue.findIndex((row) => row.id === selectedId);
  const previous = data.queue[position - 1];
  const next = data.queue[position + 1];
  const ids = item?.case_ids ?? data.queue[position]?.case_ids ?? [];
  const cases = data.cases.filter((entry) => ids.includes(entry.id));
  const blocked =
    !data.can_edit ||
    item?.pairing_pending ||
    cases.length === 0 ||
    cases.some((entry) => !entry.available);
  const revision = `${item?.id}:${cases.map((entry) => `${entry.id}:${entry.basis}`).join(",")}`;
  const initialValues = cases.length === 1 ? cases[0].values : blankValues();
  const dirty =
    editorRevision === revision && JSON.stringify(values) !== JSON.stringify(initialValues);
  function go(id: string | undefined) {
    if (!id || busy || dirty) return;
    setSaved("");
    mutation.reset();
    navigate(`${base}/review/${encodeURIComponent(id)}?${params}`);
  }
  useEffect(() => () => operation.current?.abort(), []);
  useEffect(() => {
    document.title = `${item ? `Purchase ${item.number}` : "Purchase review"} · Nila`;
  }, [item]);
  useEffect(() => {
    function keyboard(event: KeyboardEvent) {
      if (
        navigationShortcutBlocked(event) ||
        event.shiftKey ||
        busy ||
        dirty ||
        !event.altKey ||
        event.ctrlKey ||
        event.metaKey
      )
        return;
      const target = event.target;
      if (
        target instanceof HTMLElement &&
        (target.isContentEditable ||
          /^(INPUT|SELECT|TEXTAREA)$/.test(target.tagName) ||
          target.closest('[role="dialog"]'))
      )
        return;
      if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
        event.preventDefault();
        go(event.key === "ArrowLeft" ? previous?.id : next?.id);
      }
    }
    window.addEventListener("keydown", keyboard);
    return () => window.removeEventListener("keydown", keyboard);
  });

  function choiceBlocked(choice: TreatmentChoice) {
    return choice === "split"
      ? cases.length !== 1
      : choice === "claim"
        ? cases.some((entry) => !entry.claimable || entry.cess_issue)
        : choice === "later" && cases.some((entry) => entry.cess_issue);
  }
  type ReviewWrite = {
    controller: AbortController;
    itemId: string;
    case_ids: number[];
    basis: Record<string, string>;
  } & (
    | {
        kind: "treatment";
        values: import("@/lib/generated/workspace").components["schemas"]["TreatmentInput"];
        andNext: boolean;
      }
    | { kind: "document" }
  );
  const mutation = useMutation({
    retry: false,
    networkMode: "always",
    mutationFn: (write: ReviewWrite) =>
      write.kind === "treatment"
        ? savePurchaseTreatment(
            String(data.client.id),
            data.period,
            write.itemId,
            data.filter,
            data.q,
            { case_ids: write.case_ids, basis: write.basis, values: write.values },
            write.controller.signal,
          )
        : recordPurchaseDocument(
            String(data.client.id),
            data.period,
            write.itemId,
            data.filter,
            data.q,
            { case_ids: write.case_ids, basis: write.basis },
            write.controller.signal,
          ),
    onSuccess: async (fresh, write) => {
      if (write.controller.signal.aborted) return;
      await cache.cancelQueries({
        queryKey: ["purchase-review", String(data.client.id), data.period],
      });
      if (write.controller.signal.aborted) return;
      void cache.invalidateQueries({
        queryKey: ["purchase-review", String(data.client.id), data.period],
        refetchType: "none",
      });
      cache.setQueryData(queryKey, fresh);
      void cache.invalidateQueries({ queryKey: ["purchases"], refetchType: "none" });
      if (write.kind === "document") {
        setSaved("Invoice possession recorded. Review the available ITC choices.");
        return;
      }
      setValues(
        cases.length === 1
          ? structuredClone(
              fresh.cases.find((entry) => entry.id === cases[0].id)?.values ?? blankValues(),
            )
          : blankValues(),
      );
      setSaved("ITC treatment saved.");
      if (write.andNext) {
        const target =
          fresh.queue.find((row) => row.id === next?.id) ??
          fresh.queue.find((row) => row.id !== write.itemId);
        if (target) navigate(`${base}/review/${encodeURIComponent(target.id)}?${params}`);
        else setSaved("ITC treatment saved. No more items in this queue.");
      }
    },
    onError: async (failure, write) => {
      if (write.controller.signal.aborted) return;
      if (failure instanceof PurchaseReviewError && [403, 404, 409].includes(failure.status)) {
        if (write.kind === "treatment") {
          setValues(blankValues());
          setEditorRevision("");
        }
        await refresh();
        setResetVersion((value) => value + 1);
      }
    },
    onSettled: (_result, _failure, write) => {
      if (operation.current === write.controller) operation.current = null;
    },
  });
  const busy = mutation.isPending || sourceEditing;
  const canEdit = !blocked && !busy && !refreshing && !loading && editorRevision === revision;
  const error = mutation.error?.message ?? null;
  const selectionKey = queryKey.join("/");
  useEffect(() => {
    operation.current?.abort();
    operation.current = null;
    mutation.reset();
    setSaved("");
  }, [selectionKey]);
  useEffect(() => {
    if (loading) return;
    openingCases.current = structuredClone(cases);
    setValues(
      mutation.error instanceof PurchaseReviewError &&
        [403, 404, 409].includes(mutation.error.status)
        ? blankValues()
        : structuredClone(initialValues),
    );
    setEditorRevision(revision);
  }, [revision, loading, resetVersion]);
  useEffect(() => {
    const warn = (event: BeforeUnloadEvent) => {
      event.preventDefault();
    };
    if (dirty || busy) window.addEventListener("beforeunload", warn);
    return () => window.removeEventListener("beforeunload", warn);
  }, [dirty, busy]);
  useEffect(() => {
    queueRef.current?.querySelector('[aria-current="page"]')?.scrollIntoView({ block: "nearest" });
  }, [selectedId, data.queue]);
  useEffect(() => {
    setSearch(routeQuery);
  }, [routeQuery]);
  useEffect(() => {
    if (search === routeQuery || dirty || busy) return;
    const timer = setTimeout(() => {
      const nextParams = new URLSearchParams(params);
      search ? nextParams.set("q", search) : nextParams.delete("q");
      navigate(`${base}/review?${nextParams}`, { replace: true });
    }, 250);
    return () => clearTimeout(timer);
  }, [search, routeQuery, dirty, busy]);
  useEffect(() => {
    if (loading || !next) return;
    void cache.prefetchQuery({
      queryKey: [
        "purchase-review",
        String(data.client.id),
        data.period,
        next.id,
        data.filter,
        data.q,
      ],
      queryFn: ({ signal }) =>
        fetchPurchaseReview(
          String(data.client.id),
          data.period,
          next.id,
          data.filter,
          data.q,
          signal,
        ),
      staleTime: 15_000,
    });
  }, [loading, next?.id, data.client.id, data.period, data.filter, data.q]);

  function save(andNext: boolean) {
    if (!item || !canEdit || !values.choice || choiceBlocked(values.choice) || operation.current)
      return;
    const controller = new AbortController();
    operation.current = controller;
    setSaved("");
    mutation.mutate({
      kind: "treatment",
      controller,
      itemId: item.id,
      case_ids: openingCases.current.map((entry) => entry.id),
      basis: Object.fromEntries(openingCases.current.map((entry) => [entry.id, entry.basis])),
      values: { ...structuredClone(values), choice: values.choice as TreatmentChoice },
      andNext,
    });
  }

  function recordDocument(entry: PurchaseReviewData["cases"][number]) {
    if (
      !item ||
      busy ||
      refreshing ||
      loading ||
      dirty ||
      !data.can_edit ||
      !entry.can_record_document ||
      operation.current
    )
      return;
    const controller = new AbortController();
    operation.current = controller;
    setSaved("");
    mutation.mutate({
      kind: "document",
      controller,
      itemId: item.id,
      case_ids: [entry.id],
      basis: { [entry.id]: entry.basis },
    });
  }

  return (
    <main className="flex h-screen flex-col overflow-hidden bg-background">
      <header className="flex shrink-0 flex-wrap items-center justify-between gap-4 border-b bg-card px-6 py-4">
        <Link
          to={backTo}
          onClick={(event) => {
            if (busy || dirty) event.preventDefault();
          }}
          className="inline-flex items-center gap-2 text-sm"
        >
          <ArrowLeft className="size-4" />
          Back to purchases
        </Link>
        <div className="text-sm text-muted-foreground">
          {data.client.name} · {data.month_label}
        </div>
        <div className="flex items-center gap-2">
          <ShortcutHelpButton />
          <span className="text-sm text-muted-foreground">
            {position >= 0
              ? `${position + 1} of ${data.queue.length}`
              : `${data.queue.length} items`}
          </span>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Previous purchase"
            disabled={!previous || busy || dirty}
            onClick={() => go(previous?.id)}
          >
            <ChevronLeft />
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="Next purchase"
            disabled={!next || busy || dirty}
            onClick={() => go(next?.id)}
          >
            <ChevronRight />
          </Button>
        </div>
      </header>
      <div className="mx-auto grid min-h-0 w-full max-w-screen-2xl flex-1 gap-6 p-6 pb-24 lg:grid-cols-[280px_minmax(0,1fr)]">
        <aside aria-label="Purchase queue" className="flex min-h-0 flex-col gap-4">
          <h2 className="font-semibold">Review queue</h2>
          <NativeSelect
            aria-label="Review filter"
            value={data.filter}
            disabled={busy || dirty}
            onChange={(event) => {
              const nextParams = new URLSearchParams(params);
              nextParams.set("filter", event.target.value);
              navigate(`${base}/review?${nextParams}`);
            }}
          >
            {[
              { id: "needs_review", label: "Needs review" },
              { id: "all", label: "All items" },
              { id: "treatment", label: "ITC treatment" },
              { id: "matched", label: "Matched" },
              { id: "mismatch", label: "Mismatch" },
              { id: "books_only", label: "Books only" },
              { id: "2b_only", label: "GSTR-2B only" },
              { id: "possible", label: "Possible matches" },
              { id: "itc", label: "ITC checks" },
              { id: "carried", label: "Carried entries" },
              { id: "register", label: "Purchase books" },
              { id: "gstr2b", label: "GSTR-2B" },
            ].map((filter) => (
              <option key={filter.id} value={filter.id}>
                {filter.label}
              </option>
            ))}
          </NativeSelect>
          <Input
            value={search}
            onChange={(event) => setSearch(event.target.value.slice(0, 200))}
            placeholder="Search invoices or suppliers"
            data-shortcut-search
            aria-label="Search review queue"
            maxLength={200}
            disabled={busy || dirty}
          />
          <nav
            ref={queueRef}
            aria-label="Purchase invoices"
            className="min-h-0 flex-1 overflow-auto rounded-lg border bg-card"
          >
            {data.queue.map((row) => (
              <button
                key={row.id}
                type="button"
                disabled={busy || dirty}
                aria-current={row.id === selectedId ? "page" : undefined}
                onClick={() => go(row.id)}
                className={`block w-full border-b px-3 py-3 text-left text-sm last:border-0 hover:bg-muted focus-visible:outline-2 focus-visible:outline-ring ${row.id === selectedId ? "bg-muted" : ""}`}
              >
                <span className="flex justify-between gap-2 font-medium">
                  <span className="min-w-0 truncate" title={row.number}>
                    {row.number}
                  </span>
                  <span className="shrink-0 tabular-nums">{row.tax}</span>
                </span>
                <span className="mt-1 block truncate text-muted-foreground">{row.vendor}</span>
                <span className="mt-1 block text-xs text-muted-foreground">{row.status}</span>
              </button>
            ))}
          </nav>
          <p className="text-xs text-muted-foreground">Alt + ← / → moves between purchases.</p>
        </aside>
        <div className="min-h-0 min-w-0 space-y-5 overflow-y-auto pb-8" aria-busy={loading}>
          {error && (
            <p
              role="alert"
              className="rounded-lg border border-destructive/30 bg-card p-4 text-sm text-destructive"
            >
              {error}
            </p>
          )}
          {saved && (
            <p role="status" className="rounded-lg border bg-card p-4 text-sm">
              {saved}
            </p>
          )}
          {data.lock_reason && <p className="text-sm text-muted-foreground">{data.lock_reason}</p>}
          {loading ? (
            <section role="status" aria-label="Loading purchase" className="space-y-5">
              <Skeleton className="h-8 w-64" />
              <Skeleton className="h-64 w-full" />
              <Skeleton className="h-48 w-full" />
            </section>
          ) : !item ? (
            <section className="rounded-lg border bg-card p-8">
              <h1 className="text-xl font-semibold">No purchases in this queue</h1>
              <p className="mt-2 text-sm text-muted-foreground">
                Choose another filter or change your search.
              </p>
            </section>
          ) : (
            <>
              <header className="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <h1 className="text-2xl font-semibold tracking-tight">Purchase {item.number}</h1>
                  <p className="mt-1 text-sm text-muted-foreground">{item.vendor}</p>
                </div>
                <Badge variant="outline">{item.status}</Badge>
              </header>
              {item.reason && <p className="text-sm text-muted-foreground">{item.reason}</p>}
              {item.comparisons.map((comparison, index) => (
                <section
                  key={comparison.id}
                  aria-label={`Source comparison ${index + 1}`}
                  className="overflow-hidden rounded-lg border bg-card"
                >
                  {comparison.has_books && comparison.has_portal ? (
                    <Table>
                      <TableHeader>
                        <TableRow>
                          <TableHead>Invoice detail</TableHead>
                          <TableHead>Purchase books</TableHead>
                          <TableHead>GSTR-2B</TableHead>
                        </TableRow>
                      </TableHeader>
                      <TableBody>
                        {comparison.facts.map((fact) => (
                          <TableRow
                            key={fact.label}
                            className={fact.different ? "bg-muted/50" : ""}
                          >
                            <TableCell className="font-medium">
                              {fact.label}
                              {fact.different && (
                                <span className="ml-2 text-xs font-normal text-muted-foreground">
                                  Differs
                                </span>
                              )}
                            </TableCell>
                            <TableCell className="whitespace-normal">{fact.books}</TableCell>
                            <TableCell className="whitespace-normal">{fact.portal}</TableCell>
                          </TableRow>
                        ))}
                      </TableBody>
                    </Table>
                  ) : (
                    <div className="p-5">
                      <h2 className="mb-4 font-semibold">
                        {comparison.has_portal ? "GSTR-2B invoice" : "Purchase invoice"}
                      </h2>
                      <dl className="grid grid-cols-2 gap-x-8 gap-y-4 xl:grid-cols-3">
                        {comparison.facts.map((fact) => (
                          <div key={fact.label}>
                            <dt className="text-xs text-muted-foreground">{fact.label}</dt>
                            <dd className="mt-1 text-sm font-medium">
                              {comparison.has_portal ? fact.portal : fact.books}
                            </dd>
                          </div>
                        ))}
                      </dl>
                    </div>
                  )}
                  <PurchaseSourceActions
                    data={data}
                    pair={comparison}
                    disabled={!data.can_edit || dirty || mutation.isPending || refreshing}
                    onEditing={setSourceEditing}
                  />
                  {comparison.original_url && (
                    <a
                      href={comparison.original_url}
                      target="_blank"
                      rel="noreferrer"
                      className="m-4 inline-flex items-center gap-2 text-sm underline"
                    >
                      Open original source <ExternalLink className="size-3" />
                      <span className="sr-only"> (new tab)</span>
                    </a>
                  )}
                </section>
              ))}
              <section
                aria-labelledby="itc-treatment-title"
                className="space-y-4 rounded-lg border bg-card p-5"
              >
                <div className="flex flex-wrap items-center justify-between gap-3">
                  <h2 id="itc-treatment-title" className="font-semibold">
                    ITC treatment
                  </h2>
                </div>
                {item.pairing_pending && (
                  <p className="text-sm">
                    Resolve the uncertain pairing before setting ITC treatment.
                  </p>
                )}
                {cases.length === 0 && (
                  <p className="text-sm text-muted-foreground">
                    No ITC treatment is available for this item.
                  </p>
                )}
                {cases.map((entry) => (
                  <div key={entry.id} className="space-y-1 text-sm">
                    <p className="font-medium">
                      {entry.number} ·{" "}
                      {choices.find((choice) => choice.id === entry.values.choice)?.label ??
                        "Not decided yet"}
                    </p>
                    {entry.values.later_reason && (
                      <p className="text-muted-foreground">
                        {data.reasons.later.find(
                          (reason) => reason.id === entry.values.later_reason,
                        )?.label ?? entry.values.later_reason}
                      </p>
                    )}
                    {entry.values.exclude_reason && (
                      <p className="text-muted-foreground">
                        {data.reasons.exclude.find(
                          (reason) => reason.id === entry.values.exclude_reason,
                        )?.label ?? entry.values.exclude_reason}
                      </p>
                    )}
                    {entry.values.choice === "split" && (
                      <dl className="space-y-1">
                        {entry.heads.map((head) => (
                          <div key={head.id}>
                            <dt className="inline font-medium">{head.label}: </dt>
                            <dd className="inline">
                              Claim ₹{entry.values.split.claim[head.id]} · Later ₹
                              {entry.values.split.later[head.id]} · Do not claim ₹
                              {entry.values.split.exclude[head.id]}
                            </dd>
                          </div>
                        ))}
                      </dl>
                    )}
                    {entry.values.note && (
                      <p className="text-muted-foreground">{entry.values.note}</p>
                    )}
                    {entry.unavailable_reason && (
                      <p className="text-muted-foreground">{entry.unavailable_reason}</p>
                    )}
                    <p className="text-muted-foreground">
                      {entry.document_state === "held"
                        ? "Invoice possession confirmed"
                        : entry.document_state === "present"
                          ? "Purchase record available"
                          : entry.document_state === "not_held"
                            ? "Invoice not held"
                            : "Invoice possession not confirmed"}
                    </p>
                    {entry.claim_block_reason && (
                      <p className="text-muted-foreground">
                        {entry.document_state === "unknown" && entry.can_record_document
                          ? "Confirm invoice possession before claiming."
                          : entry.claim_block_reason}
                      </p>
                    )}
                    {entry.cess_issue && (
                      <p className="text-muted-foreground">{entry.cess_issue}</p>
                    )}
                    {entry.can_record_document && (
                      <Button
                        variant="outline"
                        size="sm"
                        disabled={!data.can_edit || busy || refreshing || dirty}
                        onClick={() => void recordDocument(entry)}
                      >
                        I have this invoice
                      </Button>
                    )}
                  </div>
                ))}
                {cases.length > 0 && (
                  <form
                    className="space-y-5"
                    aria-label="ITC treatment form"
                    onKeyDown={(event) => {
                      if (
                        event.key === "Enter" &&
                        (event.ctrlKey || event.metaKey) &&
                        !event.altKey &&
                        !event.shiftKey &&
                        !event.repeat &&
                        !event.nativeEvent.isComposing
                      ) {
                        event.preventDefault();
                        void save(true);
                      }
                    }}
                    onSubmit={(event) => {
                      event.preventDefault();
                      void save(false);
                    }}
                  >
                    <div className="flex flex-wrap gap-x-5 gap-y-2 text-sm">
                      {cases.length === 1 &&
                        cases[0].heads.map((head) => (
                          <p key={head.id}>
                            <span className="text-muted-foreground">{head.label}</span>{" "}
                            <span className="font-medium tabular-nums">{head.amount}</span>
                          </p>
                        ))}
                    </div>
                    <RadioGroup
                      aria-label="ITC treatment"
                      value={values.choice ?? ""}
                      disabled={!canEdit}
                      onValueChange={(value) =>
                        setValues((current) => ({ ...current, choice: value as TreatmentChoice }))
                      }
                      className="grid-cols-1 gap-3 lg:grid-cols-3"
                    >
                      {choices
                        .filter((choice) => choice.id !== "split")
                        .map((choice) => (
                          <label
                            key={choice.id}
                            className="flex cursor-pointer items-center gap-3 rounded-lg border px-3 py-3 text-sm has-data-checked:border-primary has-data-checked:bg-muted/50 has-data-disabled:cursor-not-allowed has-data-disabled:opacity-50"
                          >
                            <RadioGroupItem value={choice.id} disabled={choiceBlocked(choice.id)} />
                            <span>{choice.label}</span>
                          </label>
                        ))}
                    </RadioGroup>
                    <Button
                      type="button"
                      variant="ghost"
                      size="sm"
                      aria-pressed={values.choice === "split"}
                      disabled={!canEdit || choiceBlocked("split")}
                      onClick={() => setValues((current) => ({ ...current, choice: "split" }))}
                    >
                      Split treatment
                    </Button>
                    {cases.length > 1 && (
                      <p className="text-sm text-muted-foreground">
                        This decision applies to all {cases.length} invoices. Split treatment
                        requires one invoice.
                      </p>
                    )}
                    {(["later", "exclude"] as const)
                      .filter((kind) => values.choice === kind || values.choice === "split")
                      .map((kind) => (
                        <label key={kind} className="block space-y-2 text-sm">
                          <span>{kind === "later" ? "Why claim later?" : "Why exclude?"}</span>
                          <NativeSelect
                            value={values[`${kind}_reason`]}
                            disabled={!canEdit}
                            onChange={(event) =>
                              setValues((current) => ({
                                ...current,
                                [`${kind}_reason`]: event.target.value,
                              }))
                            }
                          >
                            <option value="">Choose a reason</option>
                            {data.reasons[kind].map((reason) => (
                              <option key={reason.id} value={reason.id}>
                                {reason.label}
                              </option>
                            ))}
                          </NativeSelect>
                        </label>
                      ))}
                    {values.choice === "split" && cases.length === 1 && (
                      <div className="space-y-4">
                        <p className="text-sm text-muted-foreground">
                          Enter rupee amounts. Each tax head must add up to its available amount.
                        </p>
                        {cases[0].heads.map((head) => (
                          <fieldset key={head.id} className="space-y-2">
                            <legend className="text-sm font-medium">
                              {head.label} available: {head.amount}
                            </legend>
                            <div className="grid grid-cols-3 gap-2">
                              {(["claim", "later", "exclude"] as const).map((part) => (
                                <label key={part} className="space-y-1 text-sm">
                                  <span>
                                    {part === "claim"
                                      ? "Claim"
                                      : part === "later"
                                        ? "Later"
                                        : "Do not claim"}
                                  </span>
                                  <Input
                                    aria-label={`${head.label} ${part}`}
                                    inputMode="decimal"
                                    disabled={
                                      !canEdit ||
                                      (head.id === "cess" && part !== "exclude") ||
                                      (part === "claim" && !cases[0].can_claim_split)
                                    }
                                    value={values.split[part][head.id]}
                                    onChange={(event) =>
                                      setValues((current) => ({
                                        ...current,
                                        split: {
                                          ...current.split,
                                          [part]: {
                                            ...current.split[part],
                                            [head.id]: event.target.value,
                                          },
                                        },
                                      }))
                                    }
                                  />
                                </label>
                              ))}
                            </div>
                          </fieldset>
                        ))}
                      </div>
                    )}
                    {values.choice && values.choice !== "claim" && (
                      <label className="block space-y-2 text-sm">
                        <span>Note</span>
                        <Textarea
                          rows={3}
                          value={values.note}
                          maxLength={1000}
                          disabled={!canEdit}
                          onChange={(event) =>
                            setValues((current) => ({ ...current, note: event.target.value }))
                          }
                        />
                      </label>
                    )}
                    <div className="fixed inset-x-0 bottom-0 z-10 flex flex-wrap items-center justify-end gap-2 border-t bg-background px-6 py-4">
                      {dirty && (
                        <p className="mr-auto text-xs text-muted-foreground">
                          Unsaved changes. Save or discard to switch purchases.
                        </p>
                      )}
                      <Button
                        type="button"
                        variant="ghost"
                        disabled={!canEdit}
                        onClick={() => setValues(structuredClone(initialValues))}
                      >
                        Discard changes
                      </Button>
                      <Button
                        type="submit"
                        variant="outline"
                        disabled={!canEdit || !values.choice || choiceBlocked(values.choice)}
                      >
                        {mutation.isPending ? "Saving…" : "Save"}
                      </Button>
                      <Button
                        type="button"
                        disabled={!canEdit || !values.choice || choiceBlocked(values.choice)}
                        onClick={() => void save(true)}
                        title="Ctrl + Enter"
                      >
                        Save and next
                      </Button>
                    </div>
                  </form>
                )}
              </section>
            </>
          )}
        </div>
      </div>
    </main>
  );
}
