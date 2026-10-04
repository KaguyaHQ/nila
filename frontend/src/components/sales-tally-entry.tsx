import { useEffect, useRef, useState } from "react";
import { CheckCircle2 } from "lucide-react";
import { toast } from "@/components/ui/toast";

import { TallyEntryEditor } from "./sales-tally-editor";
import type { SalesInvoiceReviewData } from "@/lib/sales-review-api";

import { InlineLedger } from "./sales-tally-ledger";

import { Link } from "@tanstack/react-router";

import { useIsMutating, useMutation, useQueryClient } from "@tanstack/react-query";

import { Button } from "@/components/ui/button";

import { Badge } from "@/components/ui/badge";
import { Popover, PopoverContent, PopoverTitle, PopoverTrigger } from "@/components/ui/popover";

import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";

import { urlDestination } from "@/lib/route-url";
import { ApiError } from "@/lib/sales-api";

import {
  postSalesTally,
  tallyMoney,
  tallyQueryKey,
  tallyStatus,
  updateSalesTally,
  verifySalesTally,
  type TallyMappingChanges,
  type EnabledTallySalesData,
  type TallySalesProposal,
} from "@/lib/sales-tally-api";

function LedgerReasoning({ proposal }: { proposal: TallySalesProposal }) {
  const groups: { ledger: string; basis: string; lines: number[] }[] = [];
  proposal.sales_entries.forEach((entry, index) => {
    if (!entry.basis) return;
    const ledger = entry.ledger_name ?? entry.suggested_ledger_name ?? "Unselected sales ledger";
    const group = groups.find((item) => item.ledger === ledger && item.basis === entry.basis);
    if (group) group.lines.push(index + 1);
    else groups.push({ ledger, basis: entry.basis, lines: [index + 1] });
  });
  const taxes = proposal.tax_entries.filter((entry) => entry.basis);
  if (!groups.length && !taxes.length) return null;

  return (
    <Popover>
      <PopoverTrigger render={<Button type="button" variant="ghost" size="sm" />}>
        Why these ledgers?
      </PopoverTrigger>
      <PopoverContent
        align="end"
        className="w-96 max-w-[calc(100vw-2rem)] max-h-[70vh] overflow-y-auto p-4"
      >
        <PopoverTitle>Why these ledgers?</PopoverTitle>
        <div className="space-y-4">
          {groups.map((group) => (
            <div key={`${group.ledger}:${group.basis}`} className="space-y-1">
              <p className="text-xs font-medium">
                {group.lines.length === proposal.sales_entries.length && group.lines.length > 1
                  ? `All ${group.lines.length} sales lines`
                  : `Sales ${group.lines.length === 1 ? "line" : "lines"} ${group.lines.join(", ")}`}
              </p>
              <p className="text-sm">{group.ledger}</p>
              <p className="text-xs text-muted-foreground">{group.basis}</p>
            </div>
          ))}
          {taxes.map((entry) => (
            <div key={entry.head} className="space-y-1">
              <p className="text-xs font-medium">{entry.head.toUpperCase()}</p>
              <p className="text-sm">{entry.ledger_name ?? "Unselected tax ledger"}</p>
              <p className="text-xs text-muted-foreground">{entry.basis}</p>
            </div>
          ))}
        </div>
      </PopoverContent>
    </Popover>
  );
}

export function TallyEntry({
  clientId,
  period,
  data,
  proposal,
  reviewUrl,
  editable = false,
  compact = false,
  showStatus = true,
  summary = false,
  review,
  onEditingChange,
}: {
  clientId: string;
  period: string;
  data: EnabledTallySalesData;
  proposal: TallySalesProposal;

  reviewUrl?: string;
  editable?: boolean;
  compact?: boolean;
  showStatus?: boolean;
  summary?: boolean;
  review?: SalesInvoiceReviewData;
  onEditingChange?: (editing: boolean) => void;
}) {
  const cache = useQueryClient();
  const [editing, setEditing] = useState(false);
  const [editToken, setEditToken] = useState("");
  const editButton = useRef<HTMLButtonElement>(null);
  const closeEditor = () => {
    setEditing(false);
    onEditingChange?.(false);
    requestAnimationFrame(() => editButton.current?.focus());
  };

  const operation = useRef<AbortController | null>(null);

  useEffect(() => () => operation.current?.abort(), []);

  const save = useMutation({
    mutationKey: ["tally-ledger", clientId, period, proposal.source_id],
    retry: false,
    networkMode: "always",

    mutationFn: ({
      changes,
      controller,
      token,
    }: {
      token: string;
      changes: TallyMappingChanges;
      controller: AbortController;
    }) => updateSalesTally(clientId, period, proposal.source_id, changes, controller.signal, token),

    onSuccess: async (saved, { controller }) => {
      await cache.cancelQueries({ queryKey: tallyQueryKey(clientId, period), exact: true });

      if (controller.signal.aborted) return;
      cache.setQueryData(tallyQueryKey(clientId, period), saved);
      if (review) {
        await cache.invalidateQueries({
          queryKey: ["sales-review", clientId, period, proposal.source_id],
        });
        void cache.invalidateQueries({ queryKey: ["sales"] });
        void cache.invalidateQueries({ queryKey: ["sales-reports"] });
        closeEditor();
      }
    },

    onSettled: () => {
      operation.current = null;
    },
    onError: () => {
      void cache.invalidateQueries({ queryKey: tallyQueryKey(clientId, period) });
    },
  });

  const change = (changes: TallyMappingChanges) => {
    if (save.isPending) return;

    const controller = new AbortController();
    operation.current = controller;
    save.mutate({ changes, controller, token: editing ? editToken : data.preview_token });
  };

  const canEdit =
    editable &&
    data.can_edit &&
    (!review || review.can_edit) &&
    !["pending", "posted", "unknown", "failed"].includes(proposal.status);

  const shared = { editable: canEdit && !review, pending: save.isPending };

  if (editing && review)
    return (
      <TallyEntryEditor
        review={review}
        data={data}
        proposal={proposal}
        pending={save.isPending}
        stale={!save.isPending && (editToken !== data.preview_token || !canEdit)}
        error={save.isError ? save.error.message : null}
        onSave={change}
        onCancel={closeEditor}
      />
    );

  return (
    <section aria-label="Proposed Tally entry" className="space-y-4">
      {!summary && (
        <div className="flex flex-wrap items-center justify-between gap-3">
          <h3 className="font-semibold">
            {proposal.status === "posted" ? "Tally entry" : "Proposed Tally entry"}
          </h3>
          <div className="flex flex-wrap items-center gap-2">
            <LedgerReasoning proposal={proposal} />
            {showStatus && <Badge variant="secondary">{tallyStatus(proposal.status)}</Badge>}
            {review && canEdit && (
              <Button
                ref={editButton}
                variant="outline"
                size="sm"
                onClick={() => {
                  save.reset();
                  setEditToken(data.preview_token);
                  setEditing(true);
                  onEditingChange?.(true);
                }}
              >
                Edit entry
              </Button>
            )}
          </div>
        </div>
      )}
      {!!proposal.issues.length && (
        <ul className="space-y-1 text-sm">
          {proposal.issues.map((issue) => (
            <li key={issue}>{issue}</li>
          ))}
        </ul>
      )}
      {!summary && (
        <p className="text-xs text-muted-foreground">{data.company.name} · Sales voucher</p>
      )}
      {!compact && !summary && (
        <dl className="space-y-2 text-sm">
          <div className="flex justify-between gap-4">
            <dt className="text-muted-foreground">Invoice</dt>
            <dd>{proposal.number}</dd>
          </div>
          <div className="flex justify-between gap-4">
            <dt className="text-muted-foreground">Date</dt>
            <dd>{proposal.date}</dd>
          </div>
        </dl>
      )}
      <div className="space-y-1 text-sm">
        {!summary && <p className="font-medium">Party ledger</p>}
        <InlineLedger
          {...shared}
          name={proposal.party_ledger?.name ?? null}
          identity={proposal.party_ledger?.identity ?? null}
          label="Tally party ledger"
          choices={data.party_choices}
          onChange={(value) => change({ party_ledger_identity: value })}
        />
      </div>
      <Table className="table-fixed">
        <TableHeader>
          <TableRow>
            <TableHead>{summary ? "Ledger" : "Ledger / description"}</TableHead>
            <TableHead className="w-36 text-right">Amount</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {(summary
            ? proposal.sales_summary
            : proposal.sales_entries.map((entry) => ({ line_ids: [entry.line_id], ...entry }))
          ).map((group) => {
            const entry = proposal.sales_entries.find(
              (item) => item.line_id === group.line_ids[0],
            )!;
            if (group.line_ids.length > 1)
              return (
                <TableRow key={group.line_ids.join(",")}>
                  <TableCell className="whitespace-normal">
                    <InlineLedger
                      {...shared}
                      name={group.ledger_name}
                      identity={group.ledger_identity}
                      label={`Sales ledger for all ${group.line_ids.length} bill lines`}
                      choices={data.sales_ledger_choices}
                      onChange={(value) =>
                        change({
                          line_sales_ledger_identities: Object.fromEntries(
                            group.line_ids.map((id) => [id, value]),
                          ),
                        })
                      }
                    />
                    <p className="mt-1 text-xs text-muted-foreground">
                      {group.line_ids.length} bill lines
                    </p>
                  </TableCell>
                  <TableCell className="text-right tabular-nums">
                    {tallyMoney(group.amount)}
                  </TableCell>
                </TableRow>
              );
            return (
              <TableRow key={entry.line_id}>
                <TableCell className="whitespace-normal">
                  <InlineLedger
                    {...shared}
                    name={entry.ledger_name}
                    identity={entry.ledger_identity}
                    label={`Sales ledger for ${entry.description || entry.line_id}`}
                    choices={data.sales_ledger_choices}
                    suggestedIdentity={entry.suggested_ledger_identity}
                    suggestedName={entry.suggested_ledger_name}
                    onChange={(value) =>
                      change({ line_sales_ledger_identities: { [entry.line_id]: value } })
                    }
                  />
                  {entry.description && (
                    <p className="mt-1 text-xs text-muted-foreground">{entry.description}</p>
                  )}
                </TableCell>
                <TableCell className="text-right tabular-nums">
                  {tallyMoney(entry.amount)}
                </TableCell>
              </TableRow>
            );
          })}
          {proposal.tax_entries.map((entry) => (
            <TableRow key={entry.head}>
              <TableCell className="whitespace-normal">
                <InlineLedger
                  {...shared}
                  name={entry.ledger_name}
                  identity={entry.ledger_identity}
                  label={`${entry.head.toUpperCase()} tax ledger`}
                  choices={data.tax_choices_by_head[entry.head]}
                  onChange={(value) => change({ tax_ledger_identities: { [entry.head]: value } })}
                />
                {!summary && (
                  <p className="mt-1 text-xs text-muted-foreground">{entry.head.toUpperCase()}</p>
                )}
              </TableCell>
              <TableCell className="text-right tabular-nums">{tallyMoney(entry.amount)}</TableCell>
            </TableRow>
          ))}
          <TableRow>
            <TableCell className="font-medium">{summary ? "Total" : "Customer total"}</TableCell>
            <TableCell className="text-right font-medium tabular-nums">
              {tallyMoney(proposal.grand_total)}
            </TableCell>
          </TableRow>
        </TableBody>
      </Table>
      {save.isError && (
        <p role="alert" className="text-sm">
          {save.error instanceof ApiError && save.error.status === 409
            ? "This bill or its ledger choices changed. Review the refreshed entry before choosing a ledger again."
            : save.error.message}
        </p>
      )}
      {save.isPending && (
        <p role="status" className="text-sm text-muted-foreground">
          Saving ledger choice…
        </p>
      )}
      {save.isSuccess && (
        <p role="status" className="text-sm text-muted-foreground">
          {review ? "Changes saved. Entry recalculated." : "Ledger choice saved."}
        </p>
      )}
      <div className="flex flex-wrap items-center justify-between gap-2">
        {reviewUrl && (
          <Button
            variant="outline"
            nativeButton={false}
            role="link"
            render={<Link {...urlDestination(reviewUrl)} />}
          >
            Check against bill
          </Button>
        )}
        {summary && <LedgerReasoning proposal={proposal} />}
      </div>
    </section>
  );
}

export function TallyPostingStatus({ data }: { data: EnabledTallySalesData }) {
  const count = (status: TallySalesProposal["status"]) =>
    data.proposals.filter((item) => item.status === status).length;
  const posted = count("posted");
  const pending = count("pending");
  const failed = count("failed");
  const unknown = count("unknown");
  if (!posted && !pending && !failed && !unknown) return null;
  return (
    <p
      role={failed || unknown ? "alert" : "status"}
      className="flex flex-wrap items-center gap-2 text-sm"
    >
      {!pending && !failed && !unknown && <CheckCircle2 className="size-4 text-emerald-600" aria-hidden="true" />}
      {pending
        ? `Posting to Tally… ${posted} posted, ${pending} remaining. Keep Tally and the connector open.`
        : `${posted} ${posted === 1 ? "entry" : "entries"} posted to Tally.`}
      {!!failed && <span>{failed} failed. Open the affected entries for details.</span>}
      {!!unknown && <span>{unknown} need their posting result checked.</span>}
    </p>
  );
}

export function TallyPostButton({
  clientId,

  period,

  data,
}: {
  clientId: string;

  period: string;

  data: EnabledTallySalesData;
}) {
  const cache = useQueryClient();

  const refreshing =
    useIsMutating({ mutationKey: ["tally-sync", clientId, period] }) > 0 ||
    data.sync.status === "running";

  const [preview, setPreview] = useState<EnabledTallySalesData | null>(null);

  const operation = useRef<AbortController | null>(null);

  useEffect(() => () => operation.current?.abort(), []);

  const post = useMutation({
    retry: false,

    networkMode: "always",

    mutationFn: ({
      snapshot,

      controller,
    }: {
      snapshot: EnabledTallySalesData;

      controller: AbortController;
    }) =>
      postSalesTally(
        clientId,

        period,

        {
          company_id: snapshot.company.id,

          invoice_ids: snapshot.proposals

            .filter((item) => item.status === "ready")

            .map((item) => item.source_id),

          preview_token: snapshot.preview_token,
        },

        controller.signal,
      ),

    onSuccess: async (result, { controller }) => {
      await cache.cancelQueries({ queryKey: tallyQueryKey(clientId, period), exact: true });

      if (!controller.signal.aborted) {
        cache.setQueryData(tallyQueryKey(clientId, period), result.tally);

        setPreview(null);
      }
    },

    onError: () => {
      void cache.invalidateQueries({ queryKey: tallyQueryKey(clientId, period) });
    },

    onSettled: () => {
      operation.current = null;
    },
  });

  const notifiedSubmission = useRef<number | null>(null);
  useEffect(() => {
    if (!post.isSuccess || !post.variables || notifiedSubmission.current === post.submittedAt) return;
    const submitted = post.variables.snapshot.proposals.filter(item => item.status === "ready");
    const results = submitted.map(item => data.proposals.find(current => current.source_id === item.source_id));
    if (!results.length || results.some(item => !item || !["posted", "failed", "unknown"].includes(item.status))) return;
    notifiedSubmission.current = post.submittedAt;
    const posted = results.filter(item => item?.status === "posted").length;
    const unresolved = results.length - posted;
    toast.add({
      type: unresolved ? "warning" : "success",
      title: unresolved
        ? `${posted} posted · ${unresolved} need attention`
        : `${posted} ${posted === 1 ? "entry" : "entries"} posted to Tally`,
      description: unresolved ? "Check the affected entries before trying again." : data.company.name,
      timeout: 8000,
    });
  }, [data, post.isSuccess, post.variables, post.submittedAt]);

  const ready = preview?.proposals?.filter((item) => item.status === "ready") ?? [];

  return (
    <>
      {!!data.ready_count ||
      !data.proposals.some((item) =>
        ["pending", "posted", "failed", "unknown"].includes(item.status),
      ) ? (
        <div className="flex flex-wrap items-center gap-3">
          <span className="text-sm text-muted-foreground">{tallyMoney(data.ready_total)}</span>
          <Button
            disabled={
              !data.can_post ||
              !data.preview_token ||
              !data.ready_count ||
              post.isPending ||
              refreshing
            }
            onClick={() => {
              post.reset();

              setPreview(data);
            }}
          >
            Post all {data.ready_count ?? 0} ready entries
          </Button>
        </div>
      ) : null}
      <Dialog
        open={!!preview}
        onOpenChange={(open) => {
          if (!open && !post.isPending) setPreview(null);
        }}
      >
        <DialogContent className="sm:max-w-lg" showCloseButton={!post.isPending}>
          <DialogHeader>
            <DialogTitle>Post sales entries to Tally?</DialogTitle>
            <DialogDescription>
              All {ready.length} ready entries for{" "}
              {new Intl.DateTimeFormat("en-IN", {
                month: "long",
                year: "numeric",
                timeZone: "UTC",
              }).format(new Date(`${period}-01T00:00:00Z`))}{" "}
              will be created in {preview?.company?.name}.
            </DialogDescription>
          </DialogHeader>
          <p className="text-sm text-muted-foreground">
            Includes entries hidden by search or filters.
          </p>
          <p>
            {ready.length} invoices · {tallyMoney(preview?.ready_total)}
          </p>
          <div className="max-h-64 overflow-y-auto">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Invoice / party</TableHead>
                  <TableHead className="text-right">Amount</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {ready.map((item) => (
                  <TableRow key={item.source_id}>
                    <TableCell>
                      {item.number}
                      <p className="text-xs text-muted-foreground">{item.party_ledger?.name}</p>
                    </TableCell>
                    <TableCell className="text-right tabular-nums">
                      {tallyMoney(item.grand_total)}
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
          {post.isError && (
            <p role="alert">
              {post.error.message} Close this dialog and review the refreshed entries before trying
              again.
            </p>
          )}
          {!post.isPending && preview && preview.preview_token !== data.preview_token && (
            <p role="status">
              The entries changed. Close this dialog and review the refreshed entries before
              posting.
            </p>
          )}
          <DialogFooter>
            <Button variant="outline" disabled={post.isPending} onClick={() => setPreview(null)}>
              Cancel
            </Button>
            <Button
              disabled={
                post.isPending ||
                post.isError ||
                refreshing ||
                preview?.preview_token !== data.preview_token
              }
              onClick={() => {
                if (!preview || post.isPending) return;

                const controller = new AbortController();

                operation.current = controller;

                post.mutate({ snapshot: preview, controller });
              }}
            >
              {post.isPending ? "Sending…" : "Confirm posting"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

export function TallyVerifyButton({
  clientId,

  period,

  data,
}: {
  clientId: string;

  period: string;

  data: EnabledTallySalesData;
}) {
  const cache = useQueryClient();

  const operation = useRef<AbortController | null>(null);

  useEffect(() => () => operation.current?.abort(), []);

  const verify = useMutation({
    retry: false,

    networkMode: "always",

    mutationFn: (controller: AbortController) =>
      verifySalesTally(clientId, period, controller.signal),

    onSuccess: async (result, controller) => {
      await cache.cancelQueries({ queryKey: tallyQueryKey(clientId, period), exact: true });

      if (!controller.signal.aborted)
        cache.setQueryData(tallyQueryKey(clientId, period), result.tally);
    },

    onSettled: () => {
      operation.current = null;
    },
  });

  if (
    !data.proposals.some((item) => item.status === "unknown") &&
    !verify.isPending &&
    !verify.isError
  )
    return null;

  return (
    <div className="space-y-2">
      <p className="text-sm">
        Some posting results are uncertain. Check Tally before taking further action.
      </p>
      <Button
        variant="outline"
        disabled={!data.can_edit || !data.company.is_open || verify.isPending}
        onClick={() => {
          if (verify.isPending) return;

          const controller = new AbortController();

          operation.current = controller;

          verify.mutate(controller);
        }}
      >
        {verify.isPending ? "Checking…" : "Verify entries in Tally"}
      </Button>
      {verify.isError && (
        <p role="alert" className="text-sm">
          {verify.error.message}
        </p>
      )}
    </div>
  );
}
