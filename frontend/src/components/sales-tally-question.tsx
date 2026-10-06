import { useState } from "react";
import { Button } from "@/components/ui/button";
import { InlineLedger } from "./sales-tally-ledger";
import type { EnabledTallySalesData, TallySalesProposal } from "@/lib/sales-tally-api";

export function SalesLedgerQuestion({ entry, choices, pending, onChange }: {
  entry: TallySalesProposal["sales_entries"][number];
  choices: EnabledTallySalesData["sales_ledger_choices"];
  pending: boolean;
  onChange: (identity: string) => void;
}) {
  const [searchAll, setSearchAll] = useState(false);
  const candidates = entry.candidates ?? [];
  const item = entry.description || `Bill line ${Number(entry.line_id) + 1}`;
  const taxHeads = entry.tax_rates?.map(tax => tax.head.toUpperCase()).join(" + ") || "matching-tax";
  return (
    <div className="space-y-3 py-2" role="group" aria-label={`Ledger choice for ${item}`}>
      <div className="space-y-1">
        <p className="font-medium">Which sales ledger should record {item}?</p>
        <p className="text-sm">
          HSN/SAC {entry.hsn_sac || "not captured"}
          {entry.tax_rates?.map(tax => ` · ${tax.head.toUpperCase()} ${tax.rate}%`).join("")}
        </p>
        <p className="text-sm text-muted-foreground">
          {candidates.length > 1
            ? `${candidates.length} ledgers match the configured HSN and rates. Earlier sales for this customer do not identify one choice.`
            : candidates.length === 1
              ? "This ledger matches the HSN and rates. An earlier saved choice needs confirmation."
              : "No sales ledger matches the captured HSN and rates for this date. Check the bill details or choose a different ledger."}
        </p>
      </div>
      {candidates.length > 0 && (
        <div className="space-y-2">
          {candidates.map(candidate => (
            <Button key={candidate.identity} type="button" variant="outline"
              className="h-auto w-full flex-col items-start gap-1 whitespace-normal px-3 py-2 text-left font-normal"
              disabled={pending} aria-label={`Use ${candidate.name} for ${item}`}
              onClick={() => onChange(candidate.identity)}>
              <span>{candidate.name}</span>
              <span className="text-xs text-muted-foreground">
                {candidate.history_count > 0
                  ? `${candidate.history_count} earlier ${taxHeads} ${candidate.history_count === 1 ? "sale" : "sales"} · ${candidate.party_history_count} for this customer`
                  : `No earlier ${taxHeads} sales in the synced history`}
              </span>
            </Button>
          ))}
        </div>
      )}
      {searchAll ? (
        <InlineLedger editable forcePicker pending={pending} name={null} identity={null}
          label={`Search all sales ledgers for ${item}`} choices={choices} onChange={onChange} />
      ) : (
        <Button type="button" variant="ghost" size="sm" disabled={pending} onClick={() => setSearchAll(true)}>
          Search all ledgers
        </Button>
      )}
    </div>
  );
}
