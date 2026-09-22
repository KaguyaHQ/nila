// Deliberate UI fixtures. Never used as accounting records or returned by Phoenix.
export type SalesInvoice = {
  id: string;
  number: string;
  date: string;
  customer: string;
  gstin: string;
  taxablePaise: number;
  taxPaise: number;
  totalPaise: number;
  status: "needs_review" | "ready";
  issue: string | null;
};

export const monthLabel = "June 2026";
export const clientName = "Breeze Tech";

const rows: Array<[string, string, string, number, string | null]> = [
  ["38/2026-27", "2026-06-09", "Philips India Ltd", 31000, "Confirm the HSN / SAC classification."],
  ["39/2026-27", "2026-06-10", "Sample Engineering Ltd", 46500, null],
  ["40/2026-27", "2026-06-11", "Sample Healthcare Ltd", 82400, "Confirm the customer GSTIN against the bill."],
  ["41/2026-27", "2026-06-15", "Sample Services Ltd", 96500, "Check the invoice date against the source."],
  ["42/2026-27", "2026-06-18", "Sample Facilities Ltd", 148750, null],
  ["43/2026-27", "2026-06-22", "Sample Manufacturing Ltd", 72600, "Confirm the invoice number."],
  ["44/2026-27", "2026-06-25", "Sample Trading Ltd", 124643, "Review the place of supply."],
  ["45/2026-27", "2026-06-29", "Sample Projects Ltd", 110000, null],
];

export const invoices: SalesInvoice[] = rows.map(([number, date, customer, rupees, issue], i) => {
  const taxablePaise = rupees * 100;
  const taxPaise = Math.round(taxablePaise * 0.18);
  return {
    id: `sample-${i + 1}`, number, date, customer,
    gstin: i === 0 ? "33AABCP9487A1ZG" : "33AAAAA0000A1Z5",
    taxablePaise, taxPaise, totalPaise: taxablePaise + taxPaise,
    status: issue ? "needs_review" : "ready", issue,
  };
});

export const totals = invoices.reduce((sum, invoice) => ({
  taxablePaise: sum.taxablePaise + invoice.taxablePaise,
  taxPaise: sum.taxPaise + invoice.taxPaise,
  totalPaise: sum.totalPaise + invoice.totalPaise,
}), { taxablePaise: 0, taxPaise: 0, totalPaise: 0 });

export function money(paise: number) {
  return new Intl.NumberFormat("en-IN", {
    style: "currency", currency: "INR", minimumFractionDigits: 2,
  }).format(paise / 100);
}
