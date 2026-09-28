import type { ReactNode } from "react";
import { Pencil, ChevronDown, Check, CircleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Alert, AlertTitle } from "@/components/ui/alert";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import { Separator } from "@/components/ui/separator";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import type { ReviewChange, SalesInvoiceReviewData } from "@/lib/sales-review-api";

function taxHeads(values: Record<string, string | null | undefined>, field: "rate" | "amount") {
  const supplied = ["cgst", "sgst", "igst"].filter(
    (head) => values[`${head}_${field}`] != null && values[`${head}_${field}`] !== "",
  );
  const nonzero = supplied.filter((head) => Number(values[`${head}_${field}`]) !== 0);
  return nonzero.length ? nonzero : supplied.slice(0, 1);
}

/** Rate summaries are not item lines. Amounts and checks come from Phoenix. */
export function InvoiceRateDetails({
  data,
  disabled,
  editing,
  editor,
  onEdit,
}: {
  data: SalesInvoiceReviewData;
  disabled: boolean;
  editing: { section: ReviewChange["section"]; index?: number } | null;
  editor: ReactNode;
  onEdit: (section: ReviewChange["section"], button: HTMLButtonElement, index?: number) => void;
}) {
  const total = data.totals.find((row) => row.field === "grand_total" || row.field === "total");
  const taxCalculation = data.tax_calculation;
  return (
    <div className="space-y-4">
      <section aria-label="Invoice value" className="space-y-3">
        <div className="flex items-center justify-between gap-2">
          <h2 className="text-sm font-medium">Invoice value</h2>
          <Button
            variant="outline"
            size="sm"
            disabled={disabled}
            onClick={(e) => onEdit("totals", e.currentTarget)}
          >
            <Pencil />
            Edit value
          </Button>
        </div>
        {editing?.section === "totals" ? (
          editor
        ) : (
          <p className="text-base font-semibold tabular-nums">{total?.printed ?? "Not supplied"}</p>
        )}
      </section>
      <Separator />
      <section aria-label="Tax breakdown" className="space-y-3">
        <h2 className="text-sm font-medium">Tax breakdown</h2>
        {editing?.section === "line" ? (
          <div className="space-y-3">
            <p className="text-sm text-muted-foreground">
              Editing rate component {(editing.index ?? 0) + 1}
            </p>
            {editor}
          </div>
        ) : (
          <div className="overflow-hidden rounded-lg border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Tax rate</TableHead>
                  <TableHead className="text-right">Taxable value</TableHead>
                  <TableHead className="text-right">{taxCalculation ? "GST" : "Calculated GST"}</TableHead>
                  <TableHead className="w-10">
                    <span className="sr-only">Edit</span>
                  </TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {data.lines.map((line) => (
                  <TableRow key={line.index}>
                    <TableCell className="align-top">
                      {taxHeads(line.values, "rate").map((head) => (
                        <div key={head}>
                          {head.toUpperCase()} {line.display[`${head}_rate`]}%
                        </div>
                      ))}
                    </TableCell>
                    <TableCell className="text-right align-top tabular-nums">
                      {line.display.taxable_value || "—"}
                    </TableCell>
                    <TableCell className="text-right align-top tabular-nums">
                      {taxHeads(line.values, "amount").map((head) => (
                        <div key={head}>
                          <span className="text-muted-foreground">{head.toUpperCase()} </span>
                          {line.display[`${head}_amount`]}
                        </div>
                      ))}
                    </TableCell>
                    <TableCell className="align-top">
                      <Button
                        variant="ghost"
                        size="icon-sm"
                        aria-label={`Edit rate component ${line.index + 1}`}
                        disabled={disabled}
                        onClick={(e) => onEdit("line", e.currentTarget, line.index)}
                      >
                        <Pencil />
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
        {taxCalculation && (
          <div className="space-y-1 text-sm">
            <p className="font-medium">{taxCalculation.label}</p>
            <p className="text-muted-foreground">{taxCalculation.detail}</p>
          </div>
        )}
      </section>
      <Separator />
      {!taxCalculation && total && total.status !== "unavailable" && (
        <Collapsible className="space-y-2">
          {total.status === "matches" ? (
            <p className="flex items-center gap-2 text-sm text-muted-foreground">
              <Check className="size-4" />
              Invoice value agrees with the tax breakdown.
            </p>
          ) : (
            <Alert>
              <CircleAlert />
              <AlertTitle>{total.difference} is unexplained by this breakdown.</AlertTitle>
            </Alert>
          )}
          <CollapsibleTrigger render={<Button variant="ghost" size="sm" className="group" />}>
            Show calculation
            <ChevronDown className="group-data-panel-open:rotate-180" />
          </CollapsibleTrigger>
          <CollapsibleContent>
            <Table>
              <TableBody>
                {data.totals
                  .filter((row) => row.field !== total.field)
                  .map((row) => (
                    <TableRow key={row.field}>
                      <TableCell>{row.label}</TableCell>
                      <TableCell className="text-right tabular-nums">{row.calculated}</TableCell>
                    </TableRow>
                  ))}
                <TableRow>
                  <TableCell>Amount explained by breakdown</TableCell>
                  <TableCell className="text-right tabular-nums">{total.calculated}</TableCell>
                </TableRow>
                <TableRow>
                  <TableCell>Invoice value</TableCell>
                  <TableCell className="text-right tabular-nums">{total.printed}</TableCell>
                </TableRow>
              </TableBody>
            </Table>
          </CollapsibleContent>
        </Collapsible>
      )}
    </div>
  );
}
