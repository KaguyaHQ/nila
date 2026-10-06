import { useState, type FormEvent } from "react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Popover, PopoverContent, PopoverTitle, PopoverTrigger } from "@/components/ui/popover";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { InlineLedger } from "./sales-tally-ledger";
import type { SalesInvoiceReviewData } from "@/lib/sales-review-api";
import {
  tallyMoney,
  type EnabledTallySalesData,
  type TallyMappingChanges,
  type TallySalesProposal,
} from "@/lib/sales-tally-api";

const facts = {
  invoice_number: "Invoice number",
  invoice_date: "Invoice date",
  buyer_name: "Customer on bill",
  buyer_gstin: "Customer GSTIN",
  place_of_supply: "Place of supply (state code)",
  narration: "Narration",
};
const totals = {
  printed_total_taxable: "Printed taxable total",
  printed_total_tax: "Printed tax total",
  printed_grand_total: "Printed grand total",
};

export function TallyEntryEditor({
  review,
  data,
  proposal,
  pending,
  stale,
  error,
  onSave,
  onCancel,
}: {
  review: SalesInvoiceReviewData;
  data: EnabledTallySalesData;
  proposal: TallySalesProposal;
  pending: boolean;
  stale: boolean;
  error: string | null;
  onSave: (changes: TallyMappingChanges) => void;
  onCancel: () => void;
}) {
  // Freeze the opening values. Background refreshes must not replace a user's draft.
  const [initial] = useState<Record<string, string>>(() =>
    Object.fromEntries(
      [
        ...Object.entries(review.facts),
        ...Object.entries(review.printed_totals),
        ...review.lines.flatMap((line) =>
          Object.entries({ ...line.values, description: line.values.description ||
            proposal.sales_entries.find((entry) => entry.line_id === String(line.index))?.description || "" }).map(([field, value]) => [
            `line_items[${line.index}].${field}`,
            value,
          ]),
        ),
      ].map(([field, value]) => [field, value ?? ""]),
    ),
  );
  const [values, setValues] = useState(initial);
  const [mappings, setMappings] = useState<TallyMappingChanges>({});
  const dirty =
    Object.keys(mappings).length > 0 ||
    Object.entries(values).some(([key, value]) => value !== (initial[key] ?? ""));

  const taxEntries = (["cgst", "sgst", "igst"] as const).flatMap((head) => {
    const existing = proposal.tax_entries.find((entry) => entry.head === head);
    const inDraft = review.lines.some((line) =>
      /[1-9]/.test(values[`line_items[${line.index}].${head}_amount`] ?? ""),
    );
    return existing
      ? [existing]
      : inDraft
        ? [{ head, ledger_identity: null, ledger_name: null, amount: "0" }]
        : [];
  });

  function field(path: string, label: string, type = "text", inline = false) {
    return (
      <label className="grid min-w-0 gap-1 text-xs text-muted-foreground" key={path}>
        {!inline && label}
        <Input
          className={inline && /amount/i.test(label) ? "text-right tabular-nums" : undefined}
          aria-label={label}
          type={type}
          inputMode={
            type === "text" && /amount|taxable|rate|total|price|quantity/i.test(label)
              ? "decimal"
              : undefined
          }
          value={values[path] ?? ""}
          disabled={pending}
          onChange={(event) => setValues((old) => ({ ...old, [path]: event.target.value }))}
        />
      </label>
    );
  }
  function submit(event: FormEvent) {
    event.preventDefault();
    if (pending || stale || !dirty) return;
    const source = Object.fromEntries(
      Object.entries(values).filter(([key, value]) => value !== (initial[key] ?? "")),
    );
    onSave({ ...mappings, ...(Object.keys(source).length ? { source_changes: source } : {}) });
  }
  return (
    <form
      aria-label="Edit Tally entry"
      className="space-y-4"
      onSubmit={submit}
      onKeyDown={(event) => {
        if (event.key === "Escape" && !pending && !event.defaultPrevented) {
          event.preventDefault();
          event.stopPropagation();
          onCancel();
        }
      }}
    >
      <div className="flex items-center justify-between gap-3">
        <h3 className="font-semibold">Proposed Tally entry</h3>
        <Popover>
          <PopoverTrigger
            render={<Button type="button" variant="ghost" size="sm" disabled={pending} />}
          >
            Bill details
          </PopoverTrigger>
          <PopoverContent align="end" className="w-96 max-h-[70vh] overflow-y-auto p-4">
            <PopoverTitle>Correct bill details</PopoverTitle>
            <div className="grid grid-cols-2 gap-3">
              {Object.entries(facts)
                .filter(([key]) => review.editable_fields.facts.includes(key))
                .map(([key, label]) => field(key, label, key === "invoice_date" ? "date" : "text"))}
              {Object.entries(totals)
                .filter(([key]) => review.editable_fields.totals.includes(key))
                .map(([key, label]) => field(key, label))}
            </div>
            <p className="text-xs text-muted-foreground">Applied when you save the entry.</p>
          </PopoverContent>
        </Popover>
      </div>
      <p className="text-xs text-muted-foreground">{data.company.name} · Sales voucher</p>
      <div className="space-y-1 text-sm">
        <p className="font-medium">Party ledger</p>
        <InlineLedger
          forcePicker
          editable
          pending={pending}
          label="Tally party ledger"
          name={proposal.party_ledger?.name ?? null}
          identity={mappings.party_ledger_identity ?? proposal.party_ledger?.identity ?? null}
          choices={data.party_choices}
          onChange={(identity) =>
            setMappings((old) => ({ ...old, party_ledger_identity: identity }))
          }
        />
      </div>
      <Table className="table-fixed">
        <TableHeader>
          <TableRow>
            <TableHead>Ledger / description</TableHead>
            <TableHead className="w-36 text-right">Amount</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {proposal.sales_entries.map((entry) => {
            const line = review.lines.find((item) => String(item.index) === entry.line_id);
            const prefix = `line_items[${entry.line_id}].`;
            const number = Number(entry.line_id) + 1;
            return (
              <TableRow key={entry.line_id}>
                <TableCell className="space-y-1.5 whitespace-normal align-top py-3">
                  <InlineLedger
                    forcePicker
                    editable
                    pending={pending}
                    label={`Sales ledger for line ${number}`}
                    name={entry.ledger_name}
                    identity={
                      mappings.line_sales_ledger_identities?.[entry.line_id] ??
                      entry.ledger_identity
                    }
                    choices={data.sales_ledger_choices}
                    onChange={(identity) =>
                      setMappings((old) => ({
                        ...old,
                        line_sales_ledger_identities: {
                          ...old.line_sales_ledger_identities,
                          [entry.line_id]: identity,
                        },
                      }))
                    }
                  />
                  {line ? (
                    <>
                      {entry.description && line.values.description && entry.description !== line.values.description && (
                        <p className="text-sm">{entry.description}</p>
                      )}
                      {field(prefix + "description", `Line ${number} description`, "text", true)}
                    </>
                  ) : (
                    <p className="text-xs text-muted-foreground">{entry.description}</p>
                  )}
                  {entry.suggested_ledger_name && !entry.ledger_identity && (
                    <p className="text-xs text-muted-foreground">
                      Suggested: {entry.suggested_ledger_name}
                    </p>
                  )}
                </TableCell>
                <TableCell className="space-y-1.5 align-top py-3 text-right">
                  {line ? (
                    <>
                      {field(
                        prefix + "taxable_value",
                        `Line ${number} taxable amount`,
                        "text",
                        true,
                      )}
                      <Popover>
                        <PopoverTrigger
                          aria-label={`Tax details for line ${number}`}
                          render={
                            <Button type="button" variant="ghost" size="sm" disabled={pending} />
                          }
                        >
                          Tax details
                        </PopoverTrigger>
                        <PopoverContent align="end" className="w-80 p-4">
                          <PopoverTitle>Line {number} · Tax details</PopoverTitle>
                          {field(prefix + "hsn_sac", `Line ${number} HSN/SAC`)}
                          <div className="grid grid-cols-[auto_1fr_1fr] items-center gap-2">
                            <span />
                            <span className="text-xs text-muted-foreground">Rate %</span>
                            <span className="text-xs text-muted-foreground">Amount</span>
                            {(["cgst", "sgst", "igst"] as const).map((head) => (
                              <TaxFields
                                key={head}
                                head={head}
                                rate={field(
                                  prefix + head + "_rate",
                                  `Line ${number} ${head.toUpperCase()} rate`,
                                  "text",
                                  true,
                                )}
                                amount={field(
                                  prefix + head + "_amount",
                                  `Line ${number} ${head.toUpperCase()} amount`,
                                  "text",
                                  true,
                                )}
                              />
                            ))}
                          </div>
                          <p className="text-xs text-muted-foreground">
                            Applied when you save the entry.
                          </p>
                        </PopoverContent>
                      </Popover>
                    </>
                  ) : (
                    tallyMoney(entry.amount)
                  )}
                </TableCell>
              </TableRow>
            );
          })}
          {taxEntries.map((entry) => (
            <TableRow key={entry.head}>
              <TableCell className="whitespace-normal py-3">
                <InlineLedger
                  forcePicker
                  editable
                  pending={pending}
                  label={`${entry.head.toUpperCase()} tax ledger`}
                  name={entry.ledger_name}
                  identity={mappings.tax_ledger_identities?.[entry.head] ?? entry.ledger_identity}
                  choices={data.tax_choices_by_head[entry.head]}
                  onChange={(identity) =>
                    setMappings((old) => ({
                      ...old,
                      tax_ledger_identities: {
                        ...old.tax_ledger_identities,
                        [entry.head]: identity,
                      },
                    }))
                  }
                />
              </TableCell>
              <TableCell className="text-right tabular-nums">
                {dirty ? "—" : tallyMoney(entry.amount)}
              </TableCell>
            </TableRow>
          ))}
          <TableRow>
            <TableCell className="font-medium">Customer total</TableCell>
            <TableCell className="text-right font-medium tabular-nums">
              {dirty ? "—" : tallyMoney(proposal.grand_total)}
            </TableCell>
          </TableRow>
        </TableBody>
      </Table>
      {dirty && (
        <p className="text-xs text-muted-foreground">
          Tax totals and customer total will be recalculated on Save.
        </p>
      )}
      {stale && (
        <p role="alert" className="text-sm">
          This entry changed while you were editing. Cancel and review the latest entry before
          editing again.
        </p>
      )}
      {error && (
        <p role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
      <div className="sticky bottom-0 flex items-center justify-end gap-2 border-t bg-background py-3">
        <Button type="button" variant="outline" disabled={pending} onClick={onCancel}>
          Cancel
        </Button>
        <Button type="submit" disabled={pending || stale || !dirty}>
          {pending ? "Saving…" : "Save changes"}
        </Button>
      </div>
    </form>
  );
}

function TaxFields({
  head,
  rate,
  amount,
}: {
  head: string;
  rate: React.ReactNode;
  amount: React.ReactNode;
}) {
  return (
    <>
      <span className="text-xs">{head.toUpperCase()}</span>
      {rate}
      {amount}
    </>
  );
}
