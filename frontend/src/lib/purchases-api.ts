import { ApiError } from "@/lib/sales-api";

export type PurchasesWorkspace = {
  client: { id: number; name: string; gstin: string | null };
  clients: { id: number; name: string }[];
  user: { name: string; org: string };
  period: string;
  month_label: string;
  can_edit: boolean;
  signed_off: boolean;
  lock_reason: string | null;
  processing: boolean;
  inputs: {
    books: { present: boolean; count: number; tax: string };
    portal: { present: boolean; count: number; tax: string; fetching: boolean; needs_import: boolean };
  };
  overview: {
    complete: boolean;
    comparison_available: boolean;
    remaining: number;
    buckets: { id: string; label: string; count: number; books_tax: string; portal_tax: string }[];
    itc: { recorded: boolean; claim: string; later: string; excluded: string; pending: string; carried_count: number; stale_count: number };
  };
  filters: { id: string; label: string }[];
  filter: string;
  q: string;
  rows: { id: string; number: string; date: string | null; vendor: string; gstin: string | null; document_type: string; tax: string; status: string; reason: string | null; review_url: string | null }[];
  carried: { id: string; number: string; vendor: string; tax: string; treatment: string; stale: boolean; review_url: string | null }[];
  working: { enabled: boolean; url: string; status: string; reason: string | null };
  links: { import_excel: string; uploads: string; portal: string; review: string; treatment: string; carried: string };
  notice: string;
};

export async function fetchPurchases(client: string, period: string, filter: string, q: string, signal: AbortSignal): Promise<PurchasesWorkspace> {
  const params = new URLSearchParams({ filter, q });
  const response = await fetch(`/api/workspace/purchases/${encodeURIComponent(client)}/${encodeURIComponent(period)}?${params}`, {
    credentials: "same-origin", headers: { Accept: "application/json" }, signal,
  });
  if (!response.ok) {
    const body = await response.json().catch(() => null);
    throw new ApiError(response.status, body?.error ?? "We couldn't load purchases. Please try again.");
  }
  return response.json();
}
