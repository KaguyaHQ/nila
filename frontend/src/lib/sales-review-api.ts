import { ApiError } from "./sales-api";

export type ReviewValues = Record<string, string>;
export type SalesInvoiceReviewData = {
  client: { id: number; name: string };
  period: string;
  invoice: { id: string; number: string; date: string | null; buyer_name: string | null; buyer_gstin: string | null; place_of_supply: string | null };
  facts: ReviewValues;
  lines: { index: number; values: ReviewValues; display: ReviewValues }[];
  totals: { field: string; label: string; calculated: string; printed: string; difference: string | null; status: "matches" | "mismatch" | "unavailable" }[];
  printed_totals: ReviewValues;
  checks: { label: string; title: string; detail: string | null; secondary: string | null; difference: string | null; status: "passed" | "failed" | "unavailable" }[];
  issues: { target: string; code: string; title: string; message: string; status: string; can_confirm: boolean; action_label: string | null }[];
  source: { url: string | null; name: string; pages: number[]; images: string[] } | null;
  states: { label: string; value: string }[];
  queue: { id: string; number: string; status: "needs_review" | "ready" }[];
  can_edit: boolean;
  lock_reason: string | null;
  editable_fields: { facts: string[]; line: string[]; totals: string[] };
};
export type ReviewChange = { section: "facts" | "line" | "totals"; values: ReviewValues; line_index?: number };

export class ReviewApiError extends ApiError {
  constructor(status: number, message: string, public fields: Record<string, string[]> = {}) {
    super(status, message);
  }
}

function reviewPath(client: string, period: string, invoice: string) {
  return `/api/workspace/sales/${encodeURIComponent(client)}/${encodeURIComponent(period)}/invoices/${encodeURIComponent(invoice)}`;
}
async function request(path: string, signal: AbortSignal, method = "GET", body?: unknown): Promise<SalesInvoiceReviewData> {
  const headers: Record<string, string> = { Accept: "application/json" };
  if (method !== "GET") {
    headers["Content-Type"] = "application/json";
    headers["X-CSRF-Token"] = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? "";
  }
  const response = await fetch(path, { method, headers, credentials: "same-origin", signal, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  if (!response.ok) {
    const data = await response.json().catch(() => null);
    throw new ReviewApiError(response.status, typeof data?.error === "string" ? data.error : "We couldn't load or save this invoice. Please try again.", data?.errors ?? {});
  }
  return response.json();
}
export function fetchSalesInvoice(client: string, period: string, invoice: string, signal: AbortSignal) {
  return request(reviewPath(client, period, invoice), signal);
}
export function updateSalesInvoice(client: string, period: string, invoice: string, changes: ReviewChange, signal: AbortSignal) {
  return request(reviewPath(client, period, invoice), signal, "PATCH", changes);
}
export function confirmSalesInvoiceIssue(client: string, period: string, invoice: string, target: string, signal: AbortSignal) {
  return request(`${reviewPath(client, period, invoice)}/confirm`, signal, "POST", { target });
}
